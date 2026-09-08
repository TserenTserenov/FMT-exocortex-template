#!/bin/bash
# ledger-append.sh <scale> <period> <kind> <json-data> [<source>] [--dedup-by-kind|--dedup-by-kind-and-date]
#
# Appends one event to machine/ledger/<scale>-<period>.yaml (append-only, flock-protected).
# WP-484 Ф16.1 — designed in peer-session 2026-07-24-10-wp484-ledger-implementation
# (Claude writer, Kimi peer critic — 8 fixes from turn 1, confirmed turn 3 CONSENSUS).
#
# --dedup-by-kind (added 28.07, night-cycle-day.sh independent review): callers whose
# kind is "once per period" (facts_digest) previously checked "does an event of this
# kind already exist?" THEMSELVES, outside this script's flock — a check-then-append
# race between two near-simultaneous callers (e.g. two overlapping night-cycle-day.sh
# runs) could both pass the check and both append, producing two facts_digest events
# in one day. Moving the dedup check inside the already-held flock closes that window.
# Opt-in flag, not default: most kinds (session_closed, pending, wp_status_change, ...)
# are legitimately repeatable within a period and must not be silently swallowed.
#
# --dedup-by-kind-and-date (WP-484, Hermes peer review 02.08): validates that the
# event carries an explicit target date and deduplicates the `(kind, data.for_date)`
# pair under the file lock. The canonical day-close writer now uses the target-date
# ledger; the finer key also makes retries safe against already mixed legacy files.
set -euo pipefail

# lib/ledger-publish-kick.sh (WP-503, unblocked 18.08) — single call site for
# all 5 pipeline scripts, since ledger-append.sh is the only actual writer
# they all funnel through (see the helper's own header for why it's not
# also wired into the other 4).
# shellcheck source=lib/ledger-publish-kick.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/ledger-publish-kick.sh"

usage() {
  echo "Usage: ledger-append.sh <scale:day|week|month> <period> <kind> <json-data> [<source>] [--dedup-by-kind|--dedup-by-kind-and-date]" >&2
  exit 1
}

[ $# -ge 4 ] || usage

SCALE="$1"
PERIOD="$2"
KIND="$3"
DATA_JSON="$4"
SOURCE="${5:-manual}"
DEDUP_BY_KIND=false
DEDUP_BY_KIND_AND_DATE=false
if [ "${5:-}" = "--dedup-by-kind" ]; then
  SOURCE="manual"
  DEDUP_BY_KIND=true
elif [ "${5:-}" = "--dedup-by-kind-and-date" ]; then
  SOURCE="manual"
  DEDUP_BY_KIND_AND_DATE=true
elif [ "${6:-}" = "--dedup-by-kind" ]; then
  DEDUP_BY_KIND=true
elif [ "${6:-}" = "--dedup-by-kind-and-date" ]; then
  DEDUP_BY_KIND_AND_DATE=true
fi
# Sanitize SOURCE — alnum/dash/underscore only (defense against injection via 5th arg)
SOURCE=$(echo "$SOURCE" | tr -cd 'a-zA-Z0-9_-')

# --- Whitelist validation ---
case "$SCALE" in
  day|week|month) ;;
  *) echo "ERROR: invalid scale '$SCALE' (must be day|week|month)" >&2; exit 1 ;;
esac

# session_reflection/conversational_close_done (WP-484 Ф18/Ф19, 29.07): пилотный
# ответ на вопрос рефлексии сессии и явный признак разговорной части Day Close.
# deferred_work_done (WP-484 Ф16.7/Ф18, CONCEPT-night-cycle.md §19 п.3): закрывает
# in_progress_background из session_closed -- без него Background Gate в
# protocol-open.md не может отличить "хвост доделан" от "хвост ещё идёт".
# reflection (WP-484 Ф20, 29.07, peer-session с Kimi): единый приёмник рефлексии
# поверх 3 производителей (session_reflection/pilot_answer/bot-poll) — pointer-модель
# {repo, path, sha}, не копия текста (OwnerIntegrity). Отдельный kind от
# session_reflection/pilot_answer — те остаются как есть, reflection их не заменяет.
# session_recovered_closed (WP-484 Ф49, 04.08, контракт из peer-session
# 2026-08-04-13-session-ttl-f47-draft, ход 1: Codex В4): восстановление
# карантинного семафора через session-guard.sh recover-orphaned. Отдельный
# kind от session_closed — сознательно: карантин не переименовывается обратно
# в .open и не проходит штатный Close, session_closed для него был бы ложью.
# close_ticket_issued / close_ticket_consumed / close_obligation (WP-484 Ф74б,
# 07.08, peer-session 2026-08-07-08-quick-close-runner-bypass, CONSENSUS ход 6):
# аудит-трейл ticket'ов запуска Quick Close (пара issued/consumed выявляет ticket
# без зарегистрированной выдачи = сфабрикованный) и аудируемые переходы
# обязательства Close (cancel-close / close-override — обход по явной команде
# пилота виден, не молчаливый).
# session_closed_no_reflection (WP-484, 08.08, session-guard.sh close
# --force-no-reflection): та же логика, что у session_recovered_closed —
# семафор закрылся без штатного шага session-reflection-append, session_closed
# для него был бы ложью. Отдельный kind от session_recovered_closed: разный
# исходный сбой (witness недоступен пилоту физически, не мёртвый держатель).
# multiplier_backfill_attempt (WP-484 Ф117, 2026-09-01, peer-session
# 2026-09-01-18-wp484-backlog-continue): telemetry for day-open-multiplier-
# backfill-patch.py -- one event per Open run attempting to backfill
# yesterday's WakaTime multiplier, success or not. Derives the "source
# absent for N days" classification from ledger history alone, same
# no-mutable-counter principle as day-open-r23-series-patch.py's R23 series.
case "$KIND" in
  facts_digest|pilot_answer|wp_status_change|blocked_question|close_day_done|open_day_done|close_week_done|open_week_done|session_closed|session_reflection|conversational_close_done|deferred_work_done|pending|day_rollup|wp_drift_found|pool_candidate_selected|pool_tiebreak_resolved|pool_execution_finished|reflection|week_summary|night_cycle_complete|night_cycle_verified|session_recovered_closed|sync_skipped|close_ticket_issued|close_ticket_consumed|close_obligation|session_closed_no_reflection|multiplier_backfill_attempt) ;;
  *) echo "ERROR: invalid kind '$KIND'" >&2; exit 1 ;;
esac

# --- PERIOD format validation (per-scale, Kimi turn-3 note) ---
case "$SCALE" in
  day)
    [[ "$PERIOD" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || {
      echo "ERROR: invalid period '$PERIOD' for scale=day (expected YYYY-MM-DD)" >&2
      exit 1
    }
    ;;
  week)
    [[ "$PERIOD" =~ ^[0-9]{4}-W[0-9]{2}$ ]] || {
      echo "ERROR: invalid period '$PERIOD' for scale=week (expected YYYY-Wnn)" >&2
      exit 1
    }
    ;;
  month)
    [[ "$PERIOD" =~ ^[0-9]{4}-[0-9]{2}$ ]] || {
      echo "ERROR: invalid period '$PERIOD' for scale=month (expected YYYY-MM)" >&2
      exit 1
    }
    ;;
esac

# --- pyyaml availability check ---
# Evgenii Red Team review 2026-08-19 (defect #5 class): the F6 shared resolver
# (scripts/lib/find-python3.sh, #453/#463) knows the Homebrew python3 path on
# Apple Silicon; a bare `python3 -c "import yaml"` probe here only sees
# whatever PATH's own python3 is, which can lack PyYAML on the same machine.
# Resolve once, reuse for every python3 call below (yaml AND json/stdlib —
# same interpreter, stdlib is always present once yaml import succeeds).
RESOLVER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/find-python3.sh"
if ! RESOLVED_PYTHON3=$("$RESOLVER"); then
  echo "ERROR: python3 module 'yaml' not found (pip install pyyaml)" >&2
  exit 1
fi

# --- JSON validation BEFORE lock acquisition (Kimi fix #2) ---
JSON_ERR=$(mktemp)
echo "$DATA_JSON" | "$RESOLVED_PYTHON3" -c "import json,sys; json.load(sys.stdin)" 2>"$JSON_ERR" || {
  echo "ERROR: invalid JSON data: $(cat "$JSON_ERR")" >&2
  rm -f "$JSON_ERR"
  exit 1
}
rm -f "$JSON_ERR"

# --- session_closed schema (WP-484 Ф38, peer-session 2026-08-02-19) ---
# The ledger is the cross-installation source of hours, so a session_closed whose
# author is absent or whose wp is free-form is a record every per-WP and per-agent
# sweep silently drops: 02.08 mixed `wp: WP-510` with `wp: '510'`, 01.08 held two
# events with no `agent` at all.
#
# Normalize, never reject. Cold review of the first cut caught the trap: hard
# rejection loses the whole event -- and the real callers that omit `agent` are
# alive (kimi-peer-writer, kimi-standalone on 01.08), as are composite
# (`WP-501,WP-503`) and placeholder (`—`) wp values written by the standard
# quick-close path. Losing the session entirely is a worse failure than the one
# being fixed, so an unrecognized value degrades to a greppable "unknown" with the
# original kept in wp_raw.
if [ "$KIND" = "session_closed" ]; then
  NORMALIZED=$(echo "$DATA_JSON" | "$RESOLVED_PYTHON3" -c '
import json, re, sys

WP_RE = re.compile(r"WP-\d+")

def normalize_wp(raw):
    """Returns (normalized, raw_to_keep). Composite "WP-1,WP-2" survives as-is."""
    if isinstance(raw, int):
        raw = str(raw)
    if not isinstance(raw, str):
        # A float/list/dict wp is still evidence of what the caller meant: keep it
        # verbatim rather than degrade to a bare "unknown" that hides the mistake.
        return "unknown", (None if raw is None else json.dumps(raw, ensure_ascii=False))
    if not raw.strip():
        return "unknown", None
    value = raw.strip()
    if value == "unknown":
        return "unknown", None
    parts = [p.strip() for p in value.split(",") if p.strip()]
    normalized = []
    for part in parts:
        if part.isdigit():
            part = f"WP-{part}"
        if not WP_RE.fullmatch(part):
            return "unknown", value
        normalized.append(part)
    if not normalized:
        return "unknown", value
    return ",".join(normalized), None

data = json.load(sys.stdin)
if not isinstance(data, dict):
    raise SystemExit("session_closed data must be a JSON object")

agent = data.get("agent")
if not isinstance(agent, str) or not agent.strip():
    data["agent"] = "unknown"

wp, wp_raw = normalize_wp(data.get("wp"))
data["wp"] = wp
if wp_raw is not None:
    data["wp_raw"] = wp_raw

duration = data.get("duration_min")
if duration is not None and (isinstance(duration, bool) or not isinstance(duration, (int, float)) or duration < 0):
    data["duration_min"] = None
    data["duration_known"] = False
    data["duration_reason"] = "invalid_duration"
    # A string "45" or a negative number is still what the caller observed -- keep
    # it verbatim, otherwise the rejected reading disappears without trace.
    if isinstance(duration, (int, float)) and not isinstance(duration, bool):
        data.setdefault("observed_duration_min", duration)
    else:
        data.setdefault("observed_duration_min_raw", json.dumps(duration, ensure_ascii=False))

json.dump(data, sys.stdout, ensure_ascii=False)
' 2>&1) || {
    echo "ERROR: session_closed schema check failed: $NORMALIZED" >&2
    exit 1
  }
  DATA_JSON="$NORMALIZED"
fi

if [ "$DEDUP_BY_KIND_AND_DATE" = "true" ] && ! echo "$DATA_JSON" | "$RESOLVED_PYTHON3" -c '
import json, sys
data = json.load(sys.stdin)
if not isinstance(data, dict) or not isinstance(data.get("for_date"), str) or not data["for_date"]:
    raise SystemExit(1)
'; then
  echo "ERROR: --dedup-by-kind-and-date requires JSON object data with non-empty string field 'for_date'" >&2
  exit 1
fi

IWE_LEDGER_DIR="${IWE_LEDGER_DIR:-$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/machine/ledger}"
mkdir -p "$IWE_LEDGER_DIR"

# shellcheck source=lib/ledger-path.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ledger-path.sh"
LEDGER_FILE="$(ledger_path "$SCALE" "$PERIOD")"
LOCK_FILE="${LEDGER_FILE}.lock"  # next to data, not /tmp (Kimi fix — tmpfiles.d survival)

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# The actual read-modify-write, run once under whichever lock (flock or mkdir
# fallback below) the caller acquired. Kept as a function, not inlined twice,
# so both lock paths share one implementation instead of drifting apart.
ledger_write_body() {
  # Atomic initialization (Kimi fix #5)
  if [ ! -f "$LEDGER_FILE" ]; then
    INIT_TMP="${LEDGER_FILE}.init.$$"
    cat > "$INIT_TMP" <<EOF
schema: ledger/v1
scale: $SCALE
period: "$PERIOD"
events: []
EOF
    mv "$INIT_TMP" "$LEDGER_FILE"
  fi

  # Backup before rewrite
  cp -f "$LEDGER_FILE" "${LEDGER_FILE}.bak" 2>/dev/null || true

  # Data passed via temp file, NOT string-interpolated into python source (Kimi fix #3 — critical)
  DATA_TMP=$(mktemp)
  echo "$DATA_JSON" > "$DATA_TMP"
  OUT_TMP="${LEDGER_FILE}.tmp.$$"

  set +e
  "$RESOLVED_PYTHON3" <<PYEOF
import json, sys, yaml

with open("$DATA_TMP", "r", encoding="utf-8") as f:
    data = json.load(f)

event = {"ts": "$TS", "source": "$SOURCE", "kind": "$KIND", "data": data}

# Graceful degradation on corrupt ledger (Kimi fix #8)
try:
    with open("$LEDGER_FILE", "r", encoding="utf-8") as f:
        doc = yaml.safe_load(f)
except Exception as e:
    print(f"ERROR: existing ledger file is corrupt: {e}", file=sys.stderr)
    print(f"Backup available at ${LEDGER_FILE}.bak -- restore manually before retry", file=sys.stderr)
    sys.exit(1)

# A present ledger is evidence, not a best-effort container.  Do not silently
# repair a malformed or mismatched file: that turns a broken source into a
# plausible empty ledger and makes downstream rollups report false zeroes.
if not isinstance(doc, dict):
    print("ERROR: existing ledger document must be a mapping", file=sys.stderr)
    sys.exit(1)
if doc.get("schema") != "ledger/v1":
    print(f"ERROR: existing ledger has unsupported schema {doc.get('schema')!r}", file=sys.stderr)
    sys.exit(1)
if doc.get("scale") != "$SCALE" or doc.get("period") != "$PERIOD":
    print(
        f"ERROR: existing ledger identity mismatch: expected $SCALE/$PERIOD, "
        f"got {doc.get('scale')!r}/{doc.get('period')!r}",
        file=sys.stderr,
    )
    sys.exit(1)
if not isinstance(doc.get("events"), list):
    print("ERROR: existing ledger events must be a list", file=sys.stderr)
    sys.exit(1)
if any(not isinstance(existing, dict) for existing in doc["events"]):
    print("ERROR: existing ledger contains a non-mapping event", file=sys.stderr)
    sys.exit(1)

# --dedup-by-kind (28.07): re-check for an existing event of this kind INSIDE the
# flock we already hold — closes the race a caller-side check-then-append left open
# (two near-simultaneous callers could both see "not there yet" outside the lock).
if "$DEDUP_BY_KIND" == "true" and any(e.get("kind") == "$KIND" for e in doc["events"]):
    print(f"SKIP: event of kind '$KIND' already exists in $LEDGER_FILE — not appending (--dedup-by-kind)")
    sys.exit(2)  # distinct from 0 (wrote) and 1 (error) — no OUT_TMP was created

if "$DEDUP_BY_KIND_AND_DATE" == "true":
    for_date = data["for_date"]
    duplicate = any(
        e.get("kind") == "$KIND"
        and isinstance(e.get("data"), dict)
        and (
            e["data"].get("for_date") == for_date
            or (
                "$SCALE" == "day"
                and "$PERIOD" == for_date
                and "for_date" not in e["data"]
            )
        )
        for e in doc["events"]
    )
    if duplicate:
        print(
            f"SKIP: event of kind '$KIND' with for_date '{for_date}' already exists "
            f"in $LEDGER_FILE — not appending (--dedup-by-kind-and-date)"
        )
        sys.exit(2)

doc["events"].append(event)

with open("$OUT_TMP", "w", encoding="utf-8") as f:
    yaml.dump(doc, f, allow_unicode=True, default_flow_style=False, sort_keys=False)
PYEOF
  PY_EXIT=$?
  set -e
  rm -f "$DATA_TMP"

  if [ $PY_EXIT -eq 2 ]; then
    # --dedup-by-kind skip — no OUT_TMP was created, nothing to rename or clean up
    return 0
  fi

  if [ $PY_EXIT -ne 0 ]; then
    echo "ERROR: failed to append event (ledger unchanged, backup at ${LEDGER_FILE}.bak)" >&2
    rm -f "$OUT_TMP" 2>/dev/null
    return 1
  fi

  # Atomic rename (SIGTERM/SIGKILL protection)
  mv "$OUT_TMP" "$LEDGER_FILE"
  echo "OK: event '$KIND' appended to $LEDGER_FILE"
  kick_ledger_publish
}

# mkdir-fallback lock (WP-484 30.07, peer-session with Codex): flock is absent from
# two independent environments — macOS lacks the coreutils binary outright, and the
# NixOS server HAS it (/run/current-system/sw/bin/flock) but iwe-scheduler.service's
# explicit systemd PATH= doesn't include that directory, so the unit's flock call
# fails with "command not found" even though an interactive SSH shell on the same
# host succeeds (live proof: machine/logs/day-cycle-2026-07-29.log:147-148 — a real
# night run lost its facts_digest event this way). PATH= is the real fix for the
# systemd case but out of scope here (different repo, iwe-server-config); this
# fallback covers both hosts without depending on that config being fixed first.
#
# Ownership is proven via a metadata file inside the lock dir (PID + hostname), not
# just mkdir's atomicity — an earlier draft only checked "-d $LOCKDIR still exists
# after 10 failed attempts", which any other process's live lock also satisfies,
# producing exactly the double-write race this whole mechanism exists to prevent
# (caught in review, not shipped). A lock left behind by a killed/crashed process on
# THIS host is recovered via kill -0; one from another hostname, or one whose
# metadata hasn't been written yet, is never stolen — only waited out to timeout.
if command -v flock >/dev/null 2>&1; then
  (
    flock -x -w 10 200 || { echo "ERROR: could not acquire lock within 10s" >&2; exit 1; }
    ledger_write_body
  # flock read-write, no O_TRUNC (Kimi fix: 200<> instead of 200>)
  ) 200<>"$LOCK_FILE"
  LOCK_EXIT=$?
else
  echo "WARN: flock not found in PATH — using mkdir-fallback lock (weaker guarantee than flock, recovers only same-host crashed owners)" >&2
  LOCKDIR="${LEDGER_FILE}.lockdir"
  LOCK_META="$LOCKDIR/owner"
  HOSTNAME_NOW="${HOSTNAME:-$(cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)}"
  lock_acquired=false
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    if mkdir "$LOCKDIR" 2>/dev/null; then
      lock_acquired=true
      break
    fi
    # Someone else holds it (or a stale dir from a dead process) — inspect before waiting.
    if [ -f "$LOCK_META" ]; then
      OTHER_HOST=$(awk -F= '$1=="host"{print $2}' "$LOCK_META" 2>/dev/null)
      OTHER_PID=$(awk -F= '$1=="pid"{print $2}' "$LOCK_META" 2>/dev/null)
      if [ "$OTHER_HOST" = "$HOSTNAME_NOW" ] && [ -n "$OTHER_PID" ] && ! kill -0 "$OTHER_PID" 2>/dev/null; then
        # Same host, PID confirmed dead — safe to reclaim (Codex review: never
        # steal a lock whose metadata says another host, or isn't written yet).
        rm -rf "$LOCKDIR" 2>/dev/null
        continue
      fi
    fi
    sleep 1
  done
  if [ "$lock_acquired" != "true" ]; then
    echo "ERROR: could not acquire mkdir-lock within 10s" >&2
    exit 1
  fi
  echo "host=$HOSTNAME_NOW" > "$LOCK_META"
  echo "pid=$$" >> "$LOCK_META"
  # Signal handlers terminate (not just cleanup-and-continue, Codex review) —
  # EXIT still fires the same trap for the normal-return path.
  trap 'rm -rf "$LOCKDIR" 2>/dev/null; exit 143' HUP INT TERM
  trap 'rm -rf "$LOCKDIR" 2>/dev/null' EXIT
  ledger_write_body
  LOCK_EXIT=$?
fi
exit "$LOCK_EXIT"
