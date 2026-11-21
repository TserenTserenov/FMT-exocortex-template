#!/usr/bin/env bash
#
# kimi-standalone-preflight.sh
# Hard gate for Kimi standalone sessions.
# Checks that the session was opened via session-guard.sh and is not stale.
#
# Usage: bash scripts/kimi-standalone-preflight.sh [--wp WP-N] [--slug S] [--session-id ID]
#
# With at least one filter the semaphore must match ALL given filters and be
# the only match; zero or several matches fail closed. Without filters the
# legacy "newest kimi-*.open" pick is kept for old callers, but it can adopt
# another conversation's semaphore (WP-561 incident 26.10: a peer pipeline for
# WP-568/538 wrote into the WP-561 isolate this way), so it warns on stderr.
#
# On success prints exactly one `MARKER: <path>` line: the kimi-peer-writer
# skill (step 0a.0b) recovers the semaphore it validated from that line.

set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
STALE_THRESHOLD="${IWE_SESSION_STALE_THRESHOLD:-1800}"  # 30 min

WANT_WP=""; WANT_SLUG=""; WANT_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --wp|--slug|--session-id)
      # An empty value (e.g. an unset PEER_WP) must not fall back to the unscoped newest-semaphore pick.
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "ERROR: $1 needs a non-empty value" >&2; exit 1; }
      case "$1" in --wp) WANT_WP="$2" ;; --slug) WANT_SLUG="$2" ;; *) WANT_ID="$2" ;; esac
      shift 2 ;;
    *) echo "ERROR: unknown argument: $1 (known: --wp, --slug, --session-id)" >&2; exit 1 ;;
  esac
done

SEM_FILE=""
if [ -z "$WANT_WP$WANT_SLUG$WANT_ID" ]; then
  SEM_FILE=$(ls -t "$SESSION_DIR/kimi"-*.open 2>/dev/null | head -1 || true)
  if [ -n "$SEM_FILE" ]; then
    echo "WARNING: preflight called without --wp/--slug/--session-id: took the newest Kimi semaphore ($(basename "$SEM_FILE")), which may belong to another conversation." >&2
  fi
else
  MATCHES=()
  for cand in "$SESSION_DIR"/kimi-*.open; do
    [ -f "$cand" ] || continue
    [ -z "$WANT_WP" ]   || grep -qxF "wp: $WANT_WP" "$cand"           || continue
    [ -z "$WANT_SLUG" ] || grep -qxF "slug: $WANT_SLUG" "$cand"       || continue
    [ -z "$WANT_ID" ]   || grep -qxF "session_id: $WANT_ID" "$cand"   || continue
    MATCHES+=("$cand")
  done
  if [ "${#MATCHES[@]}" -gt 1 ]; then
    echo "ERROR: ${#MATCHES[@]} Kimi semaphores match (wp='$WANT_WP' slug='$WANT_SLUG' id='$WANT_ID'); refusing to guess:" >&2
    printf '  %s\n' "${MATCHES[@]##*/}" >&2
    exit 1
  fi
  if [ "${#MATCHES[@]}" -eq 1 ]; then
    SEM_FILE="${MATCHES[0]}"
  fi
fi

if [ -z "$SEM_FILE" ]; then
  echo "ERROR: Kimi standalone session is NOT OPEN${WANT_WP:+ for $WANT_WP}${WANT_SLUG:+ (slug $WANT_SLUG)}${WANT_ID:+ (id $WANT_ID)}." >&2
  echo "Another conversation's semaphore does not count: open your own first:" >&2
  echo "  bash \"\${IWE_SCRIPTS:-\$HOME/IWE/scripts}/session-guard.sh\" open --wp ${WANT_WP:-WP-N} --task \"...\" --agent kimi --isolate" >&2
  exit 1
fi

# The skill rebuilds the semaphore path as kimi-<session_id>.open from the
# marker name, so the id must be a safe file-name part and the file must be
# named after it; otherwise the marker would point the skill at another
# semaphore. A housekeeping semaphore (scheduled task runs) is named after its
# reason instead: kimi-housekeeping-<reason>.open with `slug: <reason>`. Its
# marker leads the skill to no file, and the skill then skips its patch.
SEM_NAME=$(basename "$SEM_FILE")
SESSION_ID=$(sed -n 's/^session_id: //p' "$SEM_FILE" | head -1)
HOUSEKEEPING=$(sed -n 's/^housekeeping: //p' "$SEM_FILE" | head -1)
SEM_SLUG=$(sed -n 's/^slug: //p' "$SEM_FILE" | head -1)
if [ -n "$HOUSEKEEPING" ]; then
  EXPECTED_NAME="kimi-housekeeping-${HOUSEKEEPING}.open"
  [ "$SEM_SLUG" = "$HOUSEKEEPING" ] || EXPECTED_NAME=""
else
  EXPECTED_NAME="kimi-${SESSION_ID}.open"
fi
if ! [[ "$SESSION_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$ ]] || [ "$SEM_NAME" != "$EXPECTED_NAME" ]; then
  echo "ERROR: semaphore $SEM_NAME has session_id '$SESSION_ID' (housekeeping '$HOUSEKEEPING') that does not match its file name; refusing to write a marker." >&2
  exit 1
fi

SEM_AGE=0
if command -v stat >/dev/null 2>&1; then
  # GNU stat first: its `stat -f` is "file system status" and succeeds (#1010 F14).
  if stat -c %Y "$SEM_FILE" >/dev/null 2>&1; then
    # Linux / Git Bash
    SEM_MTIME=$(stat -c %Y "$SEM_FILE")
  else
    # macOS
    SEM_MTIME=$(stat -f %m "$SEM_FILE")
  fi
  SEM_AGE=$(($(date +%s) - SEM_MTIME))
fi

if [ "$SEM_AGE" -gt "$STALE_THRESHOLD" ]; then
  echo "WARNING: active session $(basename "$SEM_FILE") is stale (${SEM_AGE}s)." >&2
  echo "Consider closing and reopening the session." >&2
fi

# Session-scoped marker, written in the launcher context (not the agent's).
MARKER_FILE="$IWE_ROOT/.iwe-runtime/kimi-standalone-${SESSION_ID}.marker"
mkdir -p "$IWE_ROOT/.iwe-runtime"
: > "$MARKER_FILE"
echo "MARKER: $MARKER_FILE"

echo "OK: $(basename "$SEM_FILE") (age: ${SEM_AGE}s)"
