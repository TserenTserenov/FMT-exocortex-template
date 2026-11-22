#!/bin/bash
# Extensions Gate Hook
# Event: PreToolUse (matcher: Edit, Write). This is a blocking guardrail for two
# structured file tools, not a tool-independent security boundary:
# arbitrary Bash Bash is not parsed (issue #528), which is explicitly disclosed in CLAUDE.md.
# Blocks direct editing of .claude/skills/, memory/protocol-*.md and
# update-manifest.json (the manifest defines, which skills are platform-managed, —
# editing a single file would disable the gate entirely).
#
# Invariant (Konstantin report 14.08.2026, WP-7 Phase71): permission is granted
# only when a check has been PROVABLY successful; absence or failure of any
# tool (jq, python3, corrupted manifest) — block, not pass.
# Previously the gate was fail-open: empty output `jq ... 2>/dev/null` was interpreted as
# «skill is not in the manifest» → permission; a path containing «..» returned the name of another skill;
# a symlink from one skills own directory to a platform file passed through.
#
# Exceptions:
#   - IWE (template — always allowed, except the manifest)
#   - author_mode: true in params.yaml (template author — source-of-truth in IWE,
#     propagation into FMT via template-sync.sh)
#   - issue #311: new directory .claude/skills/<name>/, which does not exist in
#     update-manifest.json — a custom skill, update.sh will not touch it. extend/SKILL.md
#     documents exactly this path as the standard approach.
#   - issue #872: editing a platform-managed .claude/skills/<name>/SKILL.md, entire
#     effect of which lies ENTIRELY INSIDE a single block between the lines
#     <!-- USER-SPACE --> and <!-- /USER-SPACE --> (update.sh preserves this block
#     on update; scripts/add-skill-markers.sh adds it to L1-skills).
#     The decision is made based on the INVARIANT of the resulting document, not based on
#     old_string/new_string: we read the file contents AFTER the call and require
#     byte-for-byte identical markers, the same text before the opening and after the closing
#     marker. The exception applies ONLY to a regular existing file with. The exception applies ONLY to a regular existing file with
#     by physical path <workspace>/.claude/skills/<name>/SKILL.md; for any
#     other file (other hooks, settings, CLAUDE.md, adjacent skill files,
#     memory/protocol-*) it changes nothing: the previous hook decision is preserved
#     as is (in particular, the hook still does not-still does not allow writes to .claude/hooks/*).
#     Any parse error/read error = block (fail-closed); no python3 — exception
#     does not apply.
#     Membership of a skill in the platform layer is proven by BRANCH ORDER, not by
#     markers: exception 3 (#311) earlier releases any skill, whose directory
#     is absent from the read manifest, therefore only skills that reach this point are those,
#     recorded in the manifest. Residual risk: content verification and the write itself
#     are not atomic with respect to the tool (race condition when the file is replaced between them), and the hook cannot
#     pass the verified inode to the tool -- it remains a guardrail against accidental inode — it remains guardrail against accidental
#     edits, not a security boundary (see. CLAUDE.md §9, Extensions Gate).

block() {
  printf '{"decision": "block", "reason": "⛔ Extensions Gate: %s"}\n' "$1"
  exit 0
}

# issue #872: decides whether ONE Edit/Write call changes nothing but the text
# strictly between the USER-SPACE markers of an existing platform SKILL.md.
# stdin = the PreToolUse payload; argv = workspace, real path (symlinks resolved), raw path.
# Prints exactly "ALLOW" or "DENY:<reason>"; any other output (or none) = deny.
IFS= read -r -d '' USER_SPACE_PY <<'PYEOF' || true
import json
import os
import stat
import sys

OPEN = b"<!-- USER-SPACE -->"
CLOSE = b"<!-- /USER-SPACE -->"
MAX_BYTES = 16 * 1024 * 1024
WHY_MARKERS = "the file does not contain exactly one valid pair of USER-SPACE markers USER-SPACE"


class Deny(Exception):
    pass


def parse(data):
    """Split into (prefix, open line, middle, close line, suffix) or raise Deny.

    Well-formed = exactly one line equal to the opening marker, exactly one
    line equal to the closing marker (a trailing CR of a CRLF file is part of
    the terminator), no other occurrence of either marker text, opening first.
    """
    if data.count(OPEN) != 1 or data.count(CLOSE) != 1:
        raise Deny(WHY_MARKERS)
    opens = []
    closes = []
    pos = 0
    size = len(data)
    while pos < size:
        nl = data.find(b"\n", pos)
        end = size if nl < 0 else nl + 1
        body = data[pos:end]
        if body.endswith(b"\n"):
            body = body[:-1]
        if body.endswith(b"\r"):
            body = body[:-1]
        if body == OPEN:
            opens.append((pos, end))
        elif body == CLOSE:
            closes.append((pos, end))
        pos = end
    if len(opens) != 1 or len(closes) != 1:
        raise Deny(WHY_MARKERS)
    (o_start, o_end), (c_start, c_end) = opens[0], closes[0]
    if o_end > c_start:
        raise Deny("USER-SPACE markers USER-SPACE are in the wrong order")
    return (data[:o_start], data[o_start:o_end], data[o_end:c_start],
            data[c_start:c_end], data[c_end:])


def native_realpath(path):
    """Same canonical form the shell layer already put `ws`/`real` in:
    os.path.realpath, separators forced to '/'. On POSIX this is a no-op
    beyond realpath itself; on native Windows Python os.path.realpath
    returns backslashes, which must be normalized the same way or every
    comparison against the shell-supplied `ws` mismatches (issue #912).

    Known residual limitation (cold-review, 24.09, unverified on real
    Windows): the shell-side real_path() also runs its input through
    cygpath -m before handing it to python; this call does not -- `head`
    is derived from `raw` (the tool call's own, un-normalized file_path),
    not from the already-normalized `ws`/`real`. On native Windows Python
    this relies on os.path.realpath accepting and correctly resolving a
    forward-slash path the way cygpath -m would, which os.path generally
    does but was not exercised on a real Windows host here. If it ever
    disagrees, the mismatch fails CLOSED (Deny), not open -- worst case is
    a legitimate Windows USER-SPACE edit wrongly denied, never an
    unintended allow.
    """
    return os.path.realpath(path).replace(os.sep, "/")


def check_path(ws, real, raw):
    """Only <ws>/.claude/skills/<name>/SKILL.md reached without symlinks/aliases."""
    if not os.path.isabs(raw):
        raise Deny("file path must be absolute")
    if not real.startswith(ws + "/"):
        raise Deny("file is outside the working directory")
    parts = real[len(ws) + 1:].split("/")
    if (len(parts) != 4 or parts[0] != ".claude" or parts[1] != "skills"
            or parts[2] in ("", ".", "..") or parts[3] != "SKILL.md"):
        raise Deny("exception applies only to .claude/skills/name/SKILL.md .claude/skills/name/SKILL.md")
    comps = raw.replace("\\", "/").split("/")
    if comps[-4:] != parts:
        raise Deny("path is not canonical: symlink, different letter case or extra path segments")
    head = "/".join(comps[:-4]) or "/"
    if native_realpath(head) != ws:
        raise Deny("path is not canonical: prefix does not match the working directory")
    base = "" if head == "/" else head
    for i in range(1, 4):
        if stat.S_ISLNK(os.lstat(base + "/" + "/".join(parts[:i])).st_mode):
            raise Deny("a directory on the path to SKILL.md is a symlink")


def read_original(raw):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        fd = os.open(raw, flags)
    except OSError:
        raise Deny("SKILL.md does not exist or is a symlink: creating the file via exception is not permitted")
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise Deny("SKILL.md is not a regular file")
        if st.st_nlink != 1:
            raise Deny("SKILL.md has hard links")
        if st.st_size > MAX_BYTES:
            raise Deny("SKILL.md too large to verify")
        with os.fdopen(fd, "rb", closefd=False) as fh:
            data = fh.read(MAX_BYTES + 1)
    finally:
        os.close(fd)
    if len(data) > MAX_BYTES:
        raise Deny("SKILL.md too large to verify")
    data.decode("utf-8")  # strict: a non-UTF-8 file is not something the tools round-trip
    return data


def apply_edit(original, search, repl, replace_all):
    return original.replace(search, repl) if replace_all else original.replace(search, repl, 1)


def simulate(payload, original):
    """Return the candidate resulting documents (all must satisfy the invariant)."""
    tool = payload.get("tool_name")
    ti = payload.get("tool_input")
    if not isinstance(ti, dict):
        raise Deny("no tool_input")
    if tool not in ("Edit", "Write"):
        raise Deny("the exception applies only to Edit and Write")
    if tool == "Write":
        if "old_string" in ti or not isinstance(ti.get("content"), str):
            raise Deny("malformed Write")
        return [ti["content"].encode("utf-8")]
    if "content" in ti or not isinstance(ti.get("old_string"), str) \
            or not isinstance(ti.get("new_string"), str):
        raise Deny("malformed Edit")
    replace_all = ti.get("replace_all", False)
    if not isinstance(replace_all, bool):
        raise Deny("invalid replace_all")
    old = ti["old_string"].encode("utf-8")
    new = ti["new_string"].encode("utf-8")
    if not old:
        raise Deny("empty old_string")
    count = original.count(old)
    if count == 0:
        raise Deny("old_string not found in file")
    if count > 1 and not replace_all:
        raise Deny("old_string appears more than once")
    results = [apply_edit(original, old, new, replace_all)]
    # The Edit tool, when deleting text (new_string == ""), also removes the
    # newline that follows old_string - the pair CR LF in a CRLF file (observed on
    # the real tool). Judge every reading; all of them must pass.
    if not new and not old.endswith(b"\n"):
        for terminator in (b"\n", b"\r\n"):
            if (old + terminator) in original:
                results.append(apply_edit(original, old + terminator, new, replace_all))
    return results


def main():
    ws, real, raw = sys.argv[1], sys.argv[2], sys.argv[3]
    payload = json.loads(sys.stdin.buffer.read().decode("utf-8"))
    if not isinstance(payload, dict):
        raise Deny("payload not an object")
    tool_input = payload.get("tool_input")
    # The shell layer read the path through jq and command substitution; the
    # path judged here must be byte-for-byte the one the tool will open.
    if not isinstance(tool_input, dict) or tool_input.get("file_path") != raw:
        raise Deny("path in the call does not match the verified path")
    check_path(ws, real, raw)
    original = read_original(raw)
    pre, open_line, _block, close_line, post = parse(original)
    for result in simulate(payload, original):
        # The invariant on the RESULT: still exactly one well-formed pair, the
        # marker lines and everything outside them byte-identical. Only the
        # block between the markers may differ.
        r_pre, r_open, _r_block, r_close, r_post = parse(result)
        if (r_pre, r_open, r_close, r_post) != (pre, open_line, close_line, post):
            raise Deny("edit falls outside the USER-SPACE block or modifies the markers themselves USER-SPACE or modifies the markers themselves")


try:
    main()
    out = "ALLOW"
except Deny as exc:
    out = "DENY:" + str(exc)
except Exception:
    out = "DENY:failed to parse file or call — blocking"
sys.stdout.buffer.write(out.encode("utf-8"))
PYEOF

INPUT=$(cat)

# Fail-closed parsing: no jq → we cannot classify the path at all.
if ! command -v jq >/dev/null 2>&1; then
  block "jq not found — the gate cannot verify the path. Install jq (brew install jq / apt install jq) and try again."
fi
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
if [ -n "$INPUT" ] && [ -z "$FILE_PATH" ]; then
  # Matcher is Edit|Write: a payload without file_path is an anomaly, not a norm.
  block "failed to extract file path from call (malformed payload) — edit cannot be classified, blocking."
fi

# Every compared path goes through one normalizer. On Windows (Git Bash),
# python3 (native Windows build) returns paths as C:\Users\... while the
# shell's `pwd -P` returns /c/Users/... -- the two never matched, and every
# file classified as external, i.e. allowed (issue #912). cygpath -m yields
# C:/Users/... for both spellings on input, and os.sep is replaced with '/'
# on the python output; POSIX systems have no cygpath and os.sep is already
# '/', so both helpers are no-ops there.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m -- "$1"
  else
    printf '%s\n' "$1"
  fi
}

real_path() {
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]).replace(os.sep, "/"))' \
    "$(native_path "$1")" 2>/dev/null
}

# Resolve symlinks: a symlink from its own skill folder to a platform file must
# be classified by TARGET, not by the symlink name. without the resolver the protection silently
# disappears — therefore its failure equals a block = block, not a fallback to the raw path.
REAL_PATH=$(real_path "$FILE_PATH")
if [ -z "$REAL_PATH" ]; then
  block "python3 unavailable or failed to normalize the path — without it symlinks cannot be verified, blocking."
fi

# Gate owns only the project workspace. A global ~/.claude skill, a sibling
# workspace and any other external path are user territory that update.sh can
# neither overwrite nor protect. Compare physical roots so symlink and prefix
# collisions cannot smuggle an internal platform file through this boundary.
WORKSPACE_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
WORKSPACE_REAL=$(real_path "$WORKSPACE_DIR")
if [ -z "$WORKSPACE_REAL" ]; then
  block "failed to normalize the working directory root — file ownership cannot be determined, blocking."
fi

# memory/ is a symlink (a junction on Windows) to the agent's auto-memory
# store, which lives outside the workspace by design. Map its physical target
# back onto memory/ so protocol-*.md reached through the link stays covered
# by this gate instead of being read as an external, unprotected path.
MEMORY_REAL=""
if [ -d "$WORKSPACE_DIR/memory" ]; then
  MEMORY_REAL=$(real_path "$WORKSPACE_DIR/memory")
fi
REL_PATH=""
if [ -n "$MEMORY_REAL" ]; then
  case "$REAL_PATH" in
    "$MEMORY_REAL"/*) REL_PATH="memory/${REAL_PATH#"$MEMORY_REAL"/}" ;;
  esac
fi
if [ -z "$REL_PATH" ]; then
  case "$REAL_PATH" in
    "$WORKSPACE_REAL"|"$WORKSPACE_REAL"/*)
      REL_PATH="${REAL_PATH#"$WORKSPACE_REAL"/}"
      ;;
    *)
      echo '{}'
      exit 0
      ;;
  esac
fi

# Traversal is rejected for in-workspace targets before ownership
# classification: «..» could otherwise derive one skill name and write another.
# Backslash form (\..\ etc.) covers a raw Windows path from the tool call.
case "$FILE_PATH" in
  *"/../"*|"../"*|*"/.."|".."|*'\..\'*|'..\'*|*'\..')
    block "path contains «..» — cannot be classified, blocking. Use a direct path without upward traversal segments."
    ;;
esac

# Manifest — always-block, BEFORE the exception for template paths: control copy
# resides inside the template clone, and editing it via Edit/Write would disable the gate.
# The standard way to modify the manifest — bash generate-manifest.sh, not Edit.
case "$REAL_PATH" in
  */update-manifest.json)
    block "update-manifest.json is modified only by the generator (bash generate-manifest.sh), not directly — this file determines, which skills are platform-level."
    ;;
esac

# Checking: is this L1 file? Exact workspace-relative prefixes do not capture
# the global ~/.claude or a neighboring directory with a similar name (issue #528).
case "$REL_PATH" in
  .claude/skills/*|memory/protocol-*)

  # Exception 1: IWE — always allowed
  if printf '%s' "$REAL_PATH" | grep -q 'IWE'; then
    exit 0
  fi

  # Exception 2: author_mode in params.yaml
  if [ -f "$WORKSPACE_DIR/params.yaml" ] && grep -qE '^author_mode:\s*true' "$WORKSPACE_DIR/params.yaml" 2>/dev/null; then
    exit 0
  fi

  # Exception 3 (issue #311): custom skill — .claude/skills/<name>/ is absent
  # in the platform manifest, update.sh update.sh will not touch or overwrite it.
  # We require EXACTLY a subdirectory (name/...) — a flat file directly in .claude/skills/
  # (e.g.. SKILL-INDEX.yaml) does NOT match and is blocked below.
  if printf '%s' "$REL_PATH" | grep -qE '^\.claude/skills/[^/]+/'; then
    SKILL_NAME="${REL_PATH#\.claude/skills/}"
    SKILL_NAME="${SKILL_NAME%%/*}"
    # Manifest resolution (#564): update.sh never delivered the manifest to
    # the workspace root, so the old root-only lookup fail-closed EVERY user
    # skill edit on 0.38.11. The authoritative copy lives inside the template
    # clone. Priority (peer consensus): explicit $IWE_TEMPLATE → derived from
    # $IWE_SCRIPTS (only a scripts/ dir whose parent holds the manifest) →
    # default clone location. Deliberately NO fallback to a root copy: a
    # stale root copy is exactly the failure mode this issue is about.
    MANIFEST=""
    MANIFEST_TRIED=""
    _mf_candidates=""
    [ -n "${IWE_TEMPLATE:-}" ] && _mf_candidates="$IWE_TEMPLATE"
    if [ -n "${IWE_SCRIPTS:-}" ] && [ "$(basename "$IWE_SCRIPTS")" = "scripts" ]; then
      _mf_candidates="$_mf_candidates
$(dirname "$IWE_SCRIPTS")"
    fi
    _mf_candidates="$_mf_candidates
$WORKSPACE_DIR/IWE"
    while IFS= read -r _mf_root; do
      [ -n "$_mf_root" ] || continue
      _mf_real=$(cd "$_mf_root" 2>/dev/null && pwd -P) || { MANIFEST_TRIED="$MANIFEST_TRIED $_mf_root (directory not found);"; continue; }
      if [ -f "$_mf_real/update-manifest.json" ]; then
        MANIFEST="$_mf_real/update-manifest.json"
        break
      fi
      MANIFEST_TRIED="$MANIFEST_TRIED $_mf_real (manifest not found);"
    done <<EOF_MF
$_mf_candidates
EOF_MF
    if [ -z "$MANIFEST" ]; then
      block "update-manifest.json not found in any known location of the template:${MANIFEST_TRIED} — skill ownership cannot be proven, blocking. Set IWE_TEMPLATE=<path to the clone IWE> (or restore the clone via update.sh) and retry."
    fi
    if [ -n "$SKILL_NAME" ]; then
      # Allow only when the manifest has been PROVABLY read: check first: check first,
      # that jq sees a non-empty .files (broken JSON / key missing / empty list =
      # tool failure, not «skill not present»), and only then the match lookup.
      if jq -e '.files | type=="array" and length>0' "$MANIFEST" >/dev/null 2>&1; then
        IN_MANIFEST=$(jq -r --arg prefix ".claude/skills/${SKILL_NAME}/" \
          '.files[]? | select(.path | startswith($prefix)) | .path' \
          "$MANIFEST" 2>/dev/null | head -1)
        if [ -z "$IN_MANIFEST" ]; then
          exit 0
        fi
      else
        block "platform manifest is not readable (corrupted JSON or empty file list) — skill ownership cannot be proven, blocking. Restore update-manifest.json (git checkout or update.sh)."
      fi
    fi
  fi

  # Exception 4 (issue #872): SKILL.md of a platform skill, full file edit
  # inside the block USER-SPACE. Path format — exactly .claude/skills/<name>/SKILL.md
  # (one directory level); everything else does not reach this point and is blocked below.
  SKILL_MD_DIR=""
  case "$REL_PATH" in
    .claude/skills/*/SKILL.md)
      SKILL_MD_DIR="${REL_PATH#.claude/skills/}"
      SKILL_MD_DIR="${SKILL_MD_DIR%/SKILL.md}"
      case "$SKILL_MD_DIR" in
        ""|*/*) SKILL_MD_DIR="" ;;
      esac
      ;;
  esac
  if [ -n "$SKILL_MD_DIR" ]; then
    # Permission only on explicit ALLOW from the invariant check; empty output,
    # crash of python python or any other value = denial.
    US_VERDICT=$(printf '%s' "$INPUT" | python3 -I -c "$USER_SPACE_PY" "$WORKSPACE_REAL" "$REAL_PATH" "$FILE_PATH" 2>/dev/null)
    if [ "$US_VERDICT" = "ALLOW" ]; then
      echo '{}'
      exit 0
    fi
    case "$US_VERDICT" in
      DENY:*) US_WHY="${US_VERDICT#DENY:}" ;;
      *) US_WHY="USER-SPACE block check USER-SPACE did not complete (no python3 or failure)" ;;
    esac
    # The reason goes into a hand-built JSON string: drop quotes, backslashes and every control character.
    US_WHY=$(printf '%s' "$US_WHY" | tr '\n\r' '  ' | tr -d '"\134' | tr -d '[:cntrl:]')
    block "SKILL.md of a platform skill belongs to the platform (L1), update.sh overwrites it on update. Add your customizations ONLY between the lines <!-- USER-SPACE --> and <!-- /USER-SPACE --> of this same file: update.sh preserves this block. Everything else in the file, the markers themselves and the text before/and after them do not touch. Reason for denial: ${US_WHY}. Directory extensions/ helps only skills, that invoke it themselves load-extensions.sh (for example day-open, day-close); for the rest, including fpf, it is not readable. If in this SKILL.md there are no markers, the exception does not apply: markers in a platform skill are added by the template maintainer (scripts/add-skill-markers.sh in the template clone). Platform-level change → IWE → update.sh."
  fi

  # Block for regular users
  block "platform (L1) and user (L3) files — are different layers. Rule (CLAUDE.md §9): Author customization → extensions/*.md. Platform change → IWE → update.sh. Mixing layers = fragility on update. Create or update the required file in extensions/."
  ;;
esac

# Allow editing of regular files
echo '{}'
exit 0
