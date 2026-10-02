#!/usr/bin/env bash
# ancestry-hardening-lib.sh -- static checks shared by the smoke tests of every script
# whose delivery proof trusts git ancestry (WP-7 Ф161). Source it; it only defines
# functions and constants.
#
# A script is hardened when, before its first ancestry-sensitive git call, it exports
#   GIT_NO_REPLACE_OBJECTS=1                 (ignore refs/replace)
#   GIT_GRAFT_FILE=/dev/null/iwe-no-grafts   (ignore legacy .git/info/grafts)
# with exactly these lines: any other value can silently switch the forgery back on.

HARDEN_REPLACE_LINE='export GIT_NO_REPLACE_OBJECTS=1'
HARDEN_GRAFT_LINE='export GIT_GRAFT_FILE=/dev/null/iwe-no-grafts'

# hardening_violations <script> <ancestry-call-regex>
# One line per violated rule; empty output means the script is hardened.
hardening_violations() {
  local file="$1" call_re="$2" line_replace line_graft first_call
  line_replace=$(grep -nxF "$HARDEN_REPLACE_LINE" "$file" | head -1 | cut -d: -f1)
  line_graft=$(grep -nxF "$HARDEN_GRAFT_LINE" "$file" | head -1 | cut -d: -f1)
  # Prose in comments may mention the call; only executable lines count.
  first_call=$(grep -vn '^[[:space:]]*#' "$file" | grep -E "$call_re" | head -1 | cut -d: -f1)
  [ -n "$line_replace" ] || echo "missing exactly: $HARDEN_REPLACE_LINE"
  [ -n "$line_graft" ] || echo "missing exactly: $HARDEN_GRAFT_LINE"
  if [ -z "$first_call" ]; then
    echo "no ancestry-sensitive call matches /$call_re/ (pattern out of date?)"
    return 0
  fi
  if [ -n "$line_replace" ] && [ "$line_replace" -ge "$first_call" ]; then
    echo "GIT_NO_REPLACE_OBJECTS export (line $line_replace) is not before the first ancestry call (line $first_call)"
  fi
  if [ -n "$line_graft" ] && [ "$line_graft" -ge "$first_call" ]; then
    echo "GIT_GRAFT_FILE export (line $line_graft) is not before the first ancestry call (line $first_call)"
  fi
}

# python_scrub_blocks_violations <script>
# Python heredocs that scrub every GIT_* variable before rebuilding their own environment
# also wipe the shell-level exports above, so each must restore both protections itself.
#
# The heredoc is parsed as Python and the statements that follow the scrub, in the same
# statement list, are replayed in order; the FINAL value of both variables must be exactly
# the protective one. Straight-line mutations of `env` (update(k=v), env[k] = v, del env[k])
# are replayed. Whatever cannot be replayed faithfully is itself reported instead of being
# skipped: env.update(**x), env.pop/clear/..., env aliased or reassigned, any mutation
# inside an if/for/while/try/with/def/class (execution not guaranteed). A token in a comment
# or a string literal is never a protection. This is a regression net against accidental
# edits of the real blocks, not a defence against deliberately obfuscated code. Python 3.9+.
python_scrub_blocks_violations() {
  local py
  py=$("$(dirname "${BASH_SOURCE[0]}")/../lib/find-python3.sh" --stdlib-only) || { echo "python3 not found (find-python3.sh)"; return 0; }
  "$py" - "$1" <<'PYEOF' || echo "python analyzer failed: its silence must not read as 'no violations'"
import ast
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    lines = handle.read().splitlines()
scrub_re = re.compile(r'not key\.startswith\("GIT_"\)')
opener_re = re.compile(r"<<-?\s*['\"]?(\w+)['\"]?")
READ_ONLY_METHODS = {"get", "items", "keys", "values", "copy"}  # any other env.<name>(...) may mutate
PURE_BUILTINS = {"dict", "list", "sorted", "len", "str", "repr", "print", "set", "tuple", "bool", "any", "all"}
COMPOUND = tuple(
    getattr(ast, name)
    for name in ("If", "For", "AsyncFor", "While", "Try", "With", "AsyncWith",
                 "FunctionDef", "AsyncFunctionDef", "ClassDef", "Match")
    if hasattr(ast, name)
)

scrubs = [i for i, line in enumerate(lines) if scrub_re.search(line)]
# A block that copies os.environ without the recognised scrub idiom (say, another loop
# variable name) would go unchecked; force a decision instead of skipping it silently.
for i, line in enumerate(lines):
    if "os.environ.items()" in line and i not in scrubs:
        print(f"line {i + 1} copies os.environ.items() without the recognised GIT_* scrub idiom: no rule checks this block")
if not scrubs:
    print("no python block scrubbing GIT_* found (pattern out of date?)")
    sys.exit(0)


def heredoc_around(index):
    """(opener index, body lines) of the heredoc holding lines[index], or None."""
    for up in range(index, -1, -1):
        match = opener_re.search(lines[up])
        if not match:
            continue
        body = []
        for line in lines[up + 1:]:
            if line.strip() == match.group(1):
                break
            body.append(line)
        else:
            return None
        return (up, body) if up + len(body) >= index else None
    return None


def is_env(node):
    return isinstance(node, ast.Name) and node.id == "env"


def is_env_item(node):
    return isinstance(node, ast.Subscript) and is_env(node.value)


def literal_key(subscript):
    key = subscript.slice
    return key.value if isinstance(key, ast.Constant) and isinstance(key.value, str) else None


def passes_env(call):
    values = [*call.args, *(kw.value for kw in call.keywords)]
    return any(is_env(v) or (isinstance(v, ast.Starred) and is_env(v.value)) for v in values)


def is_harmless_consumer(call):
    """subprocess.* only reads the environment it is given; so do a few pure builtins."""
    func = call.func
    if isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name) and func.value.id == "subprocess":
        return True
    return isinstance(func, ast.Name) and func.id in PURE_BUILTINS


def mutations(stmt):
    """`env` mutations inside one statement as (position, kind, payload), in source order.

    Writes are recognised by the tree context of the node (Store/Del on `env` or on
    `env[...]`), not by a list of statement kinds, so a form nobody thought of is still
    seen. What is replayed: env.update(k=v), env[<literal>] = v (also annotated), del
    env[<literal>]. Everything else that writes to env, calls an unknown env method, or
    hands env to a callee that could mutate it is reported as opaque."""
    events = []
    handled = set()  # subscript targets already turned into precise events
    for node in ast.walk(stmt):
        pos = (getattr(node, "lineno", 0), getattr(node, "col_offset", 0))
        if isinstance(node, ast.Call):
            func = node.func
            if isinstance(func, ast.Attribute) and is_env(func.value):
                if func.attr == "update":
                    if node.args or any(kw.arg is None for kw in node.keywords):
                        events.append((pos, "opaque", "env.update with a positional or ** argument"))
                    events.extend((pos, "set", (kw.arg, kw.value)) for kw in node.keywords if kw.arg is not None)
                elif func.attr not in READ_ONLY_METHODS:
                    events.append((pos, "opaque", f"env.{func.attr}(...)"))
            elif passes_env(node) and not is_harmless_consumer(node):
                events.append((pos, "opaque", f"env handed to {ast.unparse(func)}(...), which may mutate it"))
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for target in targets:
                if not is_env_item(target):
                    continue
                handled.add(id(target))
                key = literal_key(target)
                if node.value is None:  # bare annotation, nothing is assigned
                    continue
                events.append((pos, "set", (key, node.value)) if key else (pos, "opaque", "env[<non-literal key>] = ..."))
        elif isinstance(node, ast.Delete):
            for target in node.targets:
                if not is_env_item(target):
                    continue
                handled.add(id(target))
                key = literal_key(target)
                events.append((pos, "unset", key) if key else (pos, "opaque", "del env[<non-literal key>]"))
    for node in ast.walk(stmt):
        pos = (getattr(node, "lineno", 0), getattr(node, "col_offset", 0))
        writes = isinstance(getattr(node, "ctx", None), (ast.Store, ast.Del))
        if writes and is_env(node):
            events.append((pos, "opaque", "env rebound or deleted"))
        elif writes and is_env_item(node) and id(node) not in handled:
            events.append((pos, "opaque", "env[...] written by a construct this check does not replay"))
    return sorted(events, key=lambda event: event[0])


PROTECTED = {"GIT_NO_REPLACE_OBJECTS", "GIT_GRAFT_FILE"}


def concerns_protection(event):
    _, kind, payload = event
    if kind == "opaque":
        return True
    return (payload[0] if kind == "set" else payload) in PROTECTED


def describe(event):
    _, kind, payload = event
    if kind == "opaque":
        return payload
    return f"{kind} {payload[0] if kind == 'set' else payload}"


def alias_line(stmt):
    """Line of an assignment that binds another name to `env` itself, else None."""
    for node in ast.walk(stmt):
        if isinstance(node, (ast.Assign, ast.AnnAssign, ast.NamedExpr)) and node.value is not None:
            values = node.value.elts if isinstance(node.value, (ast.Tuple, ast.List)) else [node.value]
            if any(is_env(value) for value in values):
                return node.lineno
    return None


def scrub_statement(tree, first):
    """(statement list, index) of the `env = {...}` statement that covers body line `first`."""
    for parent in ast.walk(tree):
        for field in ("body", "orelse", "finalbody"):
            block = getattr(parent, field, None)
            if not isinstance(block, list):
                continue
            for i, stmt in enumerate(block):
                if (isinstance(stmt, ast.Assign) and stmt.lineno <= first <= stmt.end_lineno
                        and any(is_env(target) for target in stmt.targets)):
                    return block, i
    return None


def is_one(value):
    return isinstance(value, ast.Constant) and value.value == "1"


def is_no_grafts_path(value):
    # os.devnull + "/iwe-no-grafts"
    return (isinstance(value, ast.BinOp) and isinstance(value.op, ast.Add)
            and isinstance(value.left, ast.Attribute) and value.left.attr == "devnull"
            and isinstance(value.left.value, ast.Name) and value.left.value.id == "os"
            and isinstance(value.right, ast.Constant) and value.right.value == "/iwe-no-grafts")


for index in scrubs:
    found = heredoc_around(index)
    if found is None:
        print(f"python block at line {index + 1}: not inside a heredoc this check can delimit (pattern out of date?)")
        continue
    up, body = found
    try:
        tree = ast.parse("\n".join(body))
    except SyntaxError as error:
        print(f"python block at line {index + 1}: heredoc does not parse as Python ({error.msg})")
        continue
    located = scrub_statement(tree, index - up)
    if located is None:
        print(f"python block at line {index + 1}: no `env = {{...}}` statement found around the scrub")
        continue
    block, position = located
    next_scrub = min((s - up for s in scrubs if up < s <= up + len(body) and s > index), default=None)
    state = {}
    for stmt in block[position + 1:]:
        if next_scrub is not None and stmt.lineno >= next_scrub:
            break
        where = up + 1 + stmt.lineno
        aliased = alias_line(stmt)
        if aliased:
            print(f"python block at line {up + 1 + aliased}: env aliased to another name, later mutations are not tracked")
        events = mutations(stmt)
        if isinstance(stmt, COMPOUND):
            # Other variables may legitimately change inside nested blocks; only the two
            # protected keys, or a mutation that could reach them, make the block unreplayable.
            relevant = [event for event in events if concerns_protection(event)]
            if relevant:
                touched = ", ".join(sorted({describe(event) for event in relevant}))
                print(f"python block at line {where}: env mutated inside a conditional or nested block, not replayable ({touched})")
            continue
        for pos, kind, payload in events:
            if kind == "opaque":
                print(f"python block at line {up + 1 + pos[0]}: env mutation this check cannot evaluate: {payload}")
            elif kind == "set":
                state[payload[0]] = payload[1]
            else:
                state.pop(payload, None)
    if not is_one(state.get("GIT_NO_REPLACE_OBJECTS")):
        print(f'python block at line {index + 1} does not finally set GIT_NO_REPLACE_OBJECTS="1" in env')
    if not is_no_grafts_path(state.get("GIT_GRAFT_FILE")):
        print(f'python block at line {index + 1} does not finally set GIT_GRAFT_FILE=os.devnull + "/iwe-no-grafts" in env')
PYEOF
}
