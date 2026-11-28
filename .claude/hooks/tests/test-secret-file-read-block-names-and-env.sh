#!/bin/bash
# test-secret-file-read-block-names-and-env.sh — the secret-file guard after the 0.42.2 checks
# (finding F3 of the attack on the released 0.42.2, finding of the rc.3 attack):
#   1. .aws/credentials, id_ecdsa and .git-credentials are denied like the other secret names,
#      while the other files of the same folders stay readable;
#   2. the old transitional variable IWE_SECRET_READ_SPLIT in the environment of the agent must
#      not switch off the check of the second path field (a secret `path` behind a plain
#      `file_path`): the re-run of the hook is marked by an argument, not by the environment.
#
# Run: bash .claude/hooks/tests/test-secret-file-read-block-names-and-env.sh
# HOOK_UNDER_TEST=<path> checks another copy of the hook (used to confirm the test fails on
# the version before the fix; the copy needs secret-bypass-lib.sh next to it).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${HOOK_UNDER_TEST:-$HOOK_DIR/secret-file-read-block.sh}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
# The hook writes its decision log under IWE_ROOT; keep it out of the real tree.
export IWE_ROOT="$TMP_DIR/iwe"
mkdir -p "$IWE_ROOT/.claude/logs"

PASS=0
FAIL=0

# check <name> <expected: deny|allow> <stdin> [NAME=value ...]: runs the hook with the extra
# variables in its environment and compares the decision.
check() {
  local name="$1" expect="$2" raw="$3" out rc got
  shift 3
  out=$(printf '%s' "$raw" | env ${1+"$@"} bash "$HOOK" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    got="rc$rc"
  elif printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then
    got=deny
  elif [ -z "$out" ]; then
    got=allow
  else
    got="other:$out"
  fi
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s: expected=%s got=%s\n' "$name" "$expect" "$got" >&2
  fi
}

# 1. Names added after finding F3 (reading is blocked) and the files next to them (reading is not).
check aws_credentials_absolute_denied deny '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.aws/credentials"}}'
check aws_credentials_relative_denied deny '{"tool_name":"Read","tool_input":{"file_path":".aws/credentials"}}'
check aws_credentials_edit_denied deny '{"tool_name":"Edit","tool_input":{"file_path":"/home/u/.aws/credentials"}}'
check aws_credentials_kimi_path_denied deny '{"tool_name":"ReadFile","tool_input":{"path":"/home/u/.aws/credentials"}}'
check id_ecdsa_denied deny '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.ssh/id_ecdsa"}}'
check id_ecdsa_pub_denied_like_id_rsa_pub deny '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.ssh/id_ecdsa.pub"}}'
check id_ecdsa_upper_case_denied deny '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.ssh/ID_ECDSA"}}'
check git_credentials_denied deny '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.git-credentials"}}'
check git_credentials_grep_denied deny '{"tool_name":"Grep","tool_input":{"path":"/home/u/.git-credentials","pattern":"x"}}'
check aws_config_allowed allow '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.aws/config"}}'
check plain_credentials_name_outside_aws_allowed allow '{"tool_name":"Read","tool_input":{"file_path":"/home/u/project/credentials"}}'
check aws_credentials_template_allowed allow '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.aws/credentials.example"}}'
check git_config_allowed allow '{"tool_name":"Read","tool_input":{"file_path":"/home/u/.gitconfig"}}'
check readme_allowed allow '{"tool_name":"Read","tool_input":{"file_path":"README.md"}}'

# Equivalent spellings must still name the same protected file. Only harmless fixtures are used.
mkdir -p "$TMP_DIR/user/.aws/sub"
printf 'fixture\n' > "$TMP_DIR/user/.aws/credentials"
for path in "$TMP_DIR/user/.aws/./credentials" "$TMP_DIR/user/.aws/sub/../credentials"; do
  check aws_equivalent_path_denied deny "$(jq -n --arg p "$path" '{tool_name:"ReadFile",tool_input:{path:$p}}')"
done
for path in 'C:\workspace\.aws\credentials' 'C:\workspace\.git-credentials' \
  'C:\workspace\.ssh\id_ecdsa' 'C:/workspace/.aws/sub/../credentials' \
  'C:\workspace\.aws.\credentials.'; do
  check windows_secret_path_denied deny "$(jq -n --arg p "$path" '{tool_name:"ReadFile",tool_input:{path:$p}}')"
done
check windows_aws_config_allowed allow '{"tool_name":"ReadFile","tool_input":{"path":"C:\\Users\\test\\.aws\\config"}}'
check protected_directory_before_parent_denied deny '{"tool_name":"ReadFile","tool_input":{"path":"/tmp/.secrets/../ordinary.txt"}}'
for name in '.env.foo\..\safe.txt' 'id_rsa.foo\..\safe.txt'; do
  printf 'fixture\n' > "$TMP_DIR/$name"
  check posix_literal_backslash_stays_protected deny "$(jq -n --arg p "$TMP_DIR/$name" '{tool_name:"ReadFile",tool_input:{path:$p}}')"
done
mkdir -p "$TMP_DIR/store/.secrets/sub" "$TMP_DIR/workspace"
printf 'fixture\n' > "$TMP_DIR/store/.secrets/db.yaml"
ln -s "$TMP_DIR/store/.secrets/sub" "$TMP_DIR/workspace/secrets"
if [ "$TMP_DIR/workspace/secrets/../db.yaml" -ef "$TMP_DIR/store/.secrets/db.yaml" ]; then
  check original_sops_path_stays_protected deny "$(jq -n --arg p "$TMP_DIR/workspace/secrets/../db.yaml" '{tool_name:"ReadFile",tool_input:{path:$p}}')"
else
  FAIL=$((FAIL + 1))
  echo 'FAIL secret path fixture does not name the same file' >&2
fi

# 2. The old variable must not switch the second path field off.
SPLIT_ENV=IWE_SECRET_READ_SPLIT=1
check split_variable_secret_path_behind_plain_file_path_denied deny \
  '{"tool_name":"ReadFile","tool_input":{"file_path":"README.md","path":".env"}}' "$SPLIT_ENV"
check split_variable_secret_file_path_behind_plain_path_denied deny \
  '{"tool_name":"ReadFile","tool_input":{"file_path":".env","path":"README.md"}}' "$SPLIT_ENV"
check split_variable_two_plain_fields_allowed allow \
  '{"tool_name":"WriteFile","tool_input":{"file_path":"README.md","path":"docs/a.md"}}' "$SPLIT_ENV"
# Control: the same input without the variable.
check no_variable_secret_path_behind_plain_file_path_denied deny \
  '{"tool_name":"ReadFile","tool_input":{"file_path":"README.md","path":".env"}}'

printf 'secret-file-read-block (names and environment): %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
