#!/usr/bin/env bash
# Проверяет WP-518 и минимальный FMT-контракт exact session transitions.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

GUARD="$ROOT_DIR/scripts/session-guard.sh"
GOV="$TMP_DIR/DS-strategy"
SESSIONS="$TMP_DIR/.iwe-runtime/sessions"

mkdir -p "$GOV/inbox/WP-001"
git -C "$GOV" init -q
git -C "$GOV" config user.name "Session Guard Test"
git -C "$GOV" config user.email "session-guard@example.invalid"
printf '%s\n' 'hypothesis_relation: "unclassified"' \
  > "$GOV/inbox/WP-001/WP-001.md"

if IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$GUARD" open --wp WP-001 --agent kimi \
  >/dev/null 2>&1; then
  echo "FAIL: unclassified WP opened a session" >&2
  exit 1
fi

printf '%s\n' 'hypothesis_relation: "tests"' \
  > "$GOV/inbox/WP-001/WP-001.md"
IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$GUARD" open --wp WP-001 --agent kimi --slug exact-a \
  --session-id exact-a --owner-pid "$$" --close-path peer-session >/dev/null

SEM_A="$SESSIONS/kimi-exact-a.open"
[ -f "$SEM_A" ] || { echo "FAIL: exact-id open did not create the expected semaphore" >&2; exit 1; }
BEFORE_SHA=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$SEM_A")
if IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$GUARD" open --wp WP-001 --agent kimi --slug exact-a \
  --session-id exact-a --owner-pid "$$" --close-path peer-session >/dev/null 2>&1; then
  echo "FAIL: duplicate exact-id open was accepted" >&2
  exit 1
fi
AFTER_SHA=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$SEM_A")
[ "$BEFORE_SHA" = "$AFTER_SHA" ] || { echo "FAIL: rejected duplicate open clobbered the semaphore" >&2; exit 1; }

IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$GUARD" open --wp WP-001 --agent kimi --slug exact-b \
  --session-id exact-b --owner-pid "$$" --close-path peer-session >/dev/null
SEM_B="$SESSIONS/kimi-exact-b.open"
mkdir -p "$TMP_DIR/scripts"
cp "$GUARD" "$TMP_DIR/scripts/session-guard.sh"

# Pointer-only callers may proceed only for a true singleton. A pointer to one
# of two sessions is not authority to guess which session owns the heartbeat.
if IWE_ROOT="$TMP_DIR" bash "$ROOT_DIR/scripts/agent-heartbeat.sh" --agent kimi >/dev/null 2>&1; then
  echo "FAIL: pointer-only heartbeat guessed among two open sessions" >&2
  exit 1
fi
if IWE_ROOT="$TMP_DIR" bash "$ROOT_DIR/scripts/kimi-auto-heartbeat.sh" --interval 1 >/dev/null 2>&1; then
  echo "FAIL: auto-heartbeat guessed among two open sessions" >&2
  exit 1
fi

printf '%s\n' 'scope fixture' > "$GOV/scoped.txt"
IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$GUARD" note-file "$GOV/scoped.txt" --agent kimi --session-id exact-a >/dev/null
grep -qxF 'file: scoped.txt' "$SEM_A" || { echo "FAIL: exact note-file missed its target" >&2; exit 1; }
if grep -qxF 'file: scoped.txt' "$SEM_B"; then
  echo "FAIL: exact note-file contaminated a sibling session" >&2
  exit 1
fi

printf '%s\n' one > "$GOV/concurrent-one.txt"
printf '%s\n' two > "$GOV/concurrent-two.txt"
IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$GUARD" note-file "$GOV/concurrent-one.txt" --agent kimi --session-id exact-a >/dev/null &
NOTE_ONE_PID=$!
IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$GUARD" note-file "$GOV/concurrent-two.txt" --agent kimi --session-id exact-a >/dev/null &
NOTE_TWO_PID=$!
wait "$NOTE_ONE_PID"
wait "$NOTE_TWO_PID"
grep -qxF 'file: concurrent-one.txt' "$SEM_A" \
  || { echo "FAIL: first serialized note was lost" >&2; exit 1; }
grep -qxF 'file: concurrent-two.txt' "$SEM_A" \
  || { echo "FAIL: second serialized note was lost" >&2; exit 1; }

IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$GUARD" heartbeat --agent kimi --session-id exact-a --owner-pid "$$" >/dev/null
grep -qxF "heartbeat_pid: $$" "$SEM_A" || { echo "FAIL: exact heartbeat was not recorded" >&2; exit 1; }
if IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$GUARD" heartbeat --agent claude-code --session-id exact-a --owner-pid "$$" >/dev/null 2>&1; then
  echo "FAIL: heartbeat accepted the wrong agent namespace" >&2
  exit 1
fi
if IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$GUARD" heartbeat --agent kimi --session-id exact-a --owner-pid 99999999 >/dev/null 2>&1; then
  echo "FAIL: heartbeat accepted a dead/non-caller PID" >&2
  exit 1
fi

LOCK_A=$(python3 - "$SEM_A" <<'PY'
import hashlib
import os
import sys
target = os.path.join(os.path.realpath(os.path.dirname(sys.argv[1])), os.path.basename(sys.argv[1]))
print(os.path.join(os.path.dirname(os.path.dirname(target)), "session-transition-locks", hashlib.sha256(target.encode()).hexdigest() + ".lock"))
PY
)
[ -f "$LOCK_A" ] || { echo "FAIL: persistent per-session lock was not created" >&2; exit 1; }
LOCK_INODE=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$LOCK_A")

git -C "$GOV" add inbox/WP-001/WP-001.md sessions scoped.txt concurrent-one.txt concurrent-two.txt
git -C "$GOV" commit -qm "test: prepare ORZ receipts"

# Observe that status-idle runs only after `.closed` is durable.
cat > "$TMP_DIR/scripts/agent-status-report.sh" <<'STATUS'
#!/usr/bin/env bash
set -euo pipefail
if [ "${6:-}" = "idle" ]; then
  sid="${2:-}"
  [ ! -e "$IWE_ROOT/.iwe-runtime/sessions/kimi-${sid}.open" ]
  [ -f "$IWE_ROOT/.iwe-runtime/sessions/kimi-${sid}.open.closed" ]
  printf '%s\n' "$sid" >> "$IWE_ROOT/.iwe-runtime/status-after-terminal.log"
fi
STATUS
chmod +x "$TMP_DIR/scripts/agent-status-report.sh"

IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$GUARD" close --agent kimi --session-id exact-a >/dev/null
[ ! -e "$SEM_A" ] && [ -f "$SEM_A.closed" ] \
  || { echo "FAIL: durable close did not leave exactly the terminal receipt" >&2; exit 1; }
python3 - "$SEM_A.closed" <<'PY'
import os
import sys
import uuid

path = sys.argv[1]
info = os.stat(path, follow_symlinks=False)
lines = open(path, encoding="utf-8").read().splitlines()

def one(key):
    prefix = key + ": "
    values = [line[len(prefix):] for line in lines if line.startswith(prefix)]
    assert len(values) == 1 and values[0]
    return values[0]

assert one("close_protocol") == "durable-v2"
attempt = uuid.UUID(one("close_attempt_id"))
assert attempt.version == 4 and str(attempt) == one("close_attempt_id")
assert one("close_destination") == os.path.join(
    os.path.realpath(os.path.dirname(path)), os.path.basename(path)
)
assert one("close_terminal_inode") == "%d:%d" % (info.st_dev, info.st_ino)
PY
grep -qxF exact-a "$TMP_DIR/.iwe-runtime/status-after-terminal.log" \
  || { echo "FAIL: status projection did not observe terminal state" >&2; exit 1; }
[ -f "$LOCK_A" ] || { echo "FAIL: transition lock inode was removed at close" >&2; exit 1; }
[ "$LOCK_INODE" = "$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$LOCK_A")" ] \
  || { echo "FAIL: transition lock inode changed" >&2; exit 1; }

if IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$GUARD" heartbeat --agent kimi --session-id exact-a --owner-pid "$$" >/dev/null 2>&1; then
  echo "FAIL: heartbeat accepted an already-closed session" >&2
  exit 1
fi
[ ! -e "$SEM_A" ] || { echo "FAIL: rejected heartbeat recreated .open" >&2; exit 1; }

# Byte-for-byte replay at the right name gets a new inode and must not pass as
# the durable receipt. Restore the original inode and prove an ordinary
# idempotent retry still succeeds.
mv "$SEM_A.closed" "$TMP_DIR/exact-a.closed.original"
cp "$TMP_DIR/exact-a.closed.original" "$SEM_A.closed"
if IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$GUARD" close --agent kimi --session-id exact-a >/dev/null 2>&1; then
  echo "FAIL: close accepted a copied receipt on a replayed inode" >&2
  exit 1
fi
mv "$SEM_A.closed" "$TMP_DIR/exact-a.closed.rejected-copy"
mv "$TMP_DIR/exact-a.closed.original" "$SEM_A.closed"
IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$GUARD" close --agent kimi --session-id exact-a >/dev/null

# Even with a valid attempt UUID and a corrected inode field, a receipt copied
# under another exact session name must fail its bound terminal destination.
REPLAY_CLOSED="$SESSIONS/kimi-replayed.open.closed"
cp "$SEM_A.closed" "$REPLAY_CLOSED"
python3 - "$REPLAY_CLOSED" <<'PY'
import os
import sys

path = sys.argv[1]
info = os.stat(path, follow_symlinks=False)
lines = open(path, encoding="utf-8").read().splitlines()
updated = []
for line in lines:
    if line == "session_id: exact-a":
        line = "session_id: replayed"
    elif line.startswith("close_terminal_inode: "):
        line = "close_terminal_inode: %d:%d" % (info.st_dev, info.st_ino)
    updated.append(line)
with open(path, "w", encoding="utf-8") as receipt:
    receipt.write("\n".join(updated) + "\n")
PY
if IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$GUARD" close --agent kimi --session-id replayed >/dev/null 2>&1; then
  echo "FAIL: close accepted a receipt replayed at another destination" >&2
  exit 1
fi

# With one exact session left, a matching pointer is accepted and a mismatching
# pointer fails closed instead of silently overriding the singleton evidence.
IWE_ROOT="$TMP_DIR" bash "$ROOT_DIR/scripts/agent-heartbeat.sh" --agent kimi >/dev/null
printf '%s\n' "$SESSIONS/kimi-not-the-session.open" > "$SESSIONS/current-kimi.ptr"
if IWE_ROOT="$TMP_DIR" bash "$ROOT_DIR/scripts/agent-heartbeat.sh" --agent kimi >/dev/null 2>&1; then
  echo "FAIL: singleton heartbeat ignored a mismatching pointer" >&2
  exit 1
fi
printf '%s\n' "$SEM_B" > "$SESSIONS/current-kimi.ptr"

# A distinct pre-existing terminal file must never be overwritten or trigger
# the old `mv || rm` fallback that deleted the only open receipt.
printf '%s\n' 'foreign terminal' > "$SEM_B.closed"
chmod 600 "$SEM_B.closed"
if IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$GUARD" close --agent kimi --session-id exact-b >/dev/null 2>&1; then
  echo "FAIL: close overwrote a foreign terminal destination" >&2
  exit 1
fi
if [ ! -f "$SEM_B" ] || ! grep -qxF 'foreign terminal' "$SEM_B.closed"; then
  echo "FAIL: close collision did not preserve both receipts" >&2
  exit 1
fi
rm -f "$SEM_B.closed"
IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$GUARD" close --agent kimi --session-id exact-b >/dev/null
B_CLOSE_ATTEMPT=$(sed -n 's/^close_attempt_id: //p' "$SEM_B.closed")
B_CLOSED_INODE=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$SEM_B.closed")

# Simulate a crash after durable hard-link publication but before unlink.
ln "$SEM_B.closed" "$SEM_B"
IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$GUARD" close --agent kimi --session-id exact-b >/dev/null
[ ! -e "$SEM_B" ] && [ -f "$SEM_B.closed" ] \
  || { echo "FAIL: close retry did not finish a same-inode terminal transition" >&2; exit 1; }
[ "$B_CLOSE_ATTEMPT" = "$(sed -n 's/^close_attempt_id: //p' "$SEM_B.closed")" ] \
  || { echo "FAIL: crash retry did not preserve the same close attempt UUID" >&2; exit 1; }
[ "$B_CLOSED_INODE" = "$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$SEM_B.closed")" ] \
  || { echo "FAIL: crash retry replaced the bound terminal inode" >&2; exit 1; }
IWE_ROOT="$TMP_DIR" IWE_GOVERNANCE_REPO="DS-strategy" \
  bash "$GUARD" close --agent kimi --session-id exact-b >/dev/null

echo "PASS: hypothesis, exact-id, no-create heartbeat and durable close contracts hold"
