#!/usr/bin/env bash
# routing: helper  called-by=archive-done-wp,week-close  deterministic=true
# see WP-5 (фаза «Проверка полноты переноса перед архивацией inbox/WP-N»), DP.SC.033
#
# check-wp-transfer-completeness.sh — проверка перед архивацией inbox/WP-N/:
#   (а) results_in в frontmatter основного WP-N.md непусто; если пусто —
#       выставляет results_not_captured: true + results_not_captured_deadline
#       (+7 дней), если ещё не проставлено;
#   (б) файлы в подпапках (кроме data/, scripts/, .venv/, node_modules/,
#       __pycache__), не упомянутые (по имени) в основном WP-N.md.
#
# Warn-not-block: не блокирует архивацию, только сигнализирует. Не exit 1 на
# найденные предупреждения — только на ошибку использования.
#
# Использование:
#   check-wp-transfer-completeness.sh <WP_NUM> [--dry-run] [IWE_ROOT]
#   check-wp-transfer-completeness.sh --all [--dry-run] [IWE_ROOT]
#
# Совместимость: bash 3.2+ (macOS), bash 4+ (Linux)

set -uo pipefail

_WPN_ROOT_UP=".."
_WPN_OPTIONAL=""
# >>> wp-num locate
# Find scripts/lib/wp-num.sh (issue #954) from THIS file's own location with symlinks
# resolved, never from IWE_WORKSPACE / IWE_ROOT / STRATEGY_DIR: callers point those at
# fixtures. Candidates, in order: lib/ next to the file, <root>/scripts/lib, the template
# clone next to a delivered workspace (<root>/FMT-exocortex-template), the explicit
# IWE_TEMPLATE. <root> is _WPN_ROOT_UP above the file's directory (set by each consumer
# just above this block: the only per-file difference, checked by test_issue_954_locate.sh).
# The library is mandatory: not finding it is an installation error, not "WP not found",
# hence exit 4 and not 1 (memory/protocol-open.md reads exit 1 as "РП не найден").
# A consumer that must keep working without the library (session-guard: its hypothesis gate
# warns and checks the exact card names, it never blocks a session over a missing library)
# sets _WPN_OPTIONAL=1 next to _WPN_ROOT_UP: WP_NUM_LIB then stays empty and nothing is sourced.
_wpn_src="${BASH_SOURCE[0]}"
_wpn_hops=0
while [ -L "$_wpn_src" ] && [ "$_wpn_hops" -lt 40 ]; do
  _wpn_link="$(readlink "$_wpn_src")"
  case "$_wpn_link" in
    /*) _wpn_src="$_wpn_link" ;;
    *) _wpn_src="$(dirname "$_wpn_src")/$_wpn_link" ;;
  esac
  _wpn_hops=$((_wpn_hops + 1))
done
_wpn_dir="$(cd -P "$(dirname "$_wpn_src")" && pwd)"
_wpn_root="$(cd -P "$_wpn_dir/$_WPN_ROOT_UP" && pwd)"
WP_NUM_LIB=""
for _wpn_cand in "$_wpn_dir/lib/wp-num.sh" \
                 "$_wpn_root/scripts/lib/wp-num.sh" \
                 "$_wpn_root/FMT-exocortex-template/scripts/lib/wp-num.sh" \
                 ${IWE_TEMPLATE:+"$IWE_TEMPLATE/scripts/lib/wp-num.sh"}; do
  if [ -r "$_wpn_cand" ]; then
    WP_NUM_LIB="$_wpn_cand"
    break
  fi
done
if [ -z "$WP_NUM_LIB" ] && [ -z "${_WPN_OPTIONAL:-}" ]; then
  echo "❌ wp-num.sh не найден (ошибка установки, это не «РП не найден»): нужен scripts/lib/wp-num.sh. Искал: ${_wpn_dir}/lib, ${_wpn_root}/scripts/lib, ${_wpn_root}/FMT-exocortex-template/scripts/lib, IWE_TEMPLATE=${IWE_TEMPLATE:-не задана}. Обновите шаблон: bash update.sh" >&2
  exit 4
fi
if [ -n "$WP_NUM_LIB" ]; then
  # shellcheck source=/dev/null
  . "$WP_NUM_LIB"
fi
# <<< wp-num locate

MODE="${1:-}"
if [[ -z "$MODE" ]]; then
  echo "Использование: $0 <WP_NUM|--all> [--dry-run] [IWE_ROOT]" >&2
  exit 1
fi
shift || true

DRY_RUN=false
IWE_ROOT_ARG=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) IWE_ROOT_ARG="$arg" ;;
  esac
done

IWE="${IWE_ROOT_ARG:-${IWE_ROOT:-$HOME/IWE}}"
INBOX="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox"

# Inspect one card: <card file> = <inbox>/WP-<N>/WP-<N>.md, the folder is its directory.
check_card() {
  local wp_file="$1"
  local wp_dir
  wp_dir=$(dirname "$wp_file")

  python3 - "$wp_file" "$wp_dir" "$DRY_RUN" <<'PYEOF'
import sys, re, os, datetime

wp_file, wp_dir, dry_run = sys.argv[1], sys.argv[2], sys.argv[3].strip().lower() == "true"
wp_num = os.path.basename(wp_file)[3:-3]

with open(wp_file, "r", encoding="utf-8") as f:
    content = f.read()

fm_match = re.match(r"^---\n(.*?)\n---\n", content, re.DOTALL)
fm = fm_match.group(1) if fm_match else ""

status_match = re.search(r"^status:\s*(.*)$", fm, re.MULTILINE)
status = (status_match.group(1).strip().strip("\"'").split()[0] if status_match and status_match.group(1).strip() else "")
CLOSING_STATUSES = {"done", "completed", "archived", "closed", "resolved-externally"}
is_closing = status in CLOSING_STATUSES

results_in_match = re.search(r"^results_in:\s*(.*)$", fm, re.MULTILINE)
results_in = (results_in_match.group(1).strip().strip("\"'") if results_in_match else "")
has_flag = re.search(r"^results_not_captured:", fm, re.MULTILINE) is not None

if not is_closing:
    pass  # WP ещё открыт (status != done/completed/archived/closed/resolved-externally) — results_in рано проверять, это не дефект
elif not results_in:
    if has_flag:
        print(f"WP-{wp_num}: warn results_in пусто (results_not_captured уже проставлен ранее)")
    else:
        deadline = (datetime.date.today() + datetime.timedelta(days=7)).isoformat()
        print(f"WP-{wp_num}: warn results_in пусто -> выставляю results_not_captured: true (дедлайн {deadline})")
        if not dry_run and fm_match:
            insert_at = fm_match.end(1)
            new_content = (
                content[:insert_at]
                + f"\nresults_not_captured: true\nresults_not_captured_deadline: {deadline}"
                + content[insert_at:]
            )
            with open(wp_file, "w", encoding="utf-8") as f:
                f.write(new_content)
else:
    print(f"WP-{wp_num}: ok results_in = {results_in}")

skip = {"data", "scripts", ".venv", "node_modules", "__pycache__"}
orphans = []
if os.path.isdir(wp_dir):
    for entry in sorted(os.listdir(wp_dir)):
        sub = os.path.join(wp_dir, entry)
        if not os.path.isdir(sub) or entry in skip:
            continue
        for root, _, files in os.walk(sub):
            for fname in files:
                full = os.path.join(root, fname)
                rel = os.path.relpath(full, wp_dir)
                if fname not in content:
                    orphans.append(rel)

if orphans:
    print(f"WP-{wp_num}: warn файлы в подпапках без упоминания в основном файле: {', '.join(orphans)}")
PYEOF
}

# Inspect the card of the WP given as typed (44, 044, WP-044). issue #954: the folder is
# WP-044/ (create-wp.sh) or the older WP-44/; the path that exists is used, and the old
# "<N> не найден — пропуск" no longer fires for a card that is simply spelled with zeros.
check_one() {
  local wp_num="$1" wp_file padded
  wp_file=$(wp_num_card_path "$INBOX" "$wp_num" || true)
  if [[ -z "$wp_file" ]]; then
    padded=$(wp_num_padded "$wp_num" || echo "$wp_num")
    echo "WP-${wp_num}: ❌ $INBOX/WP-${padded}/WP-${padded}.md не найден — пропуск"
    return
  fi
  check_card "$wp_file"
}

if [[ "$MODE" == "--all" ]]; then
  total=0
  warned=0
  for dir in "$INBOX"/WP-*/; do
    [[ -d "$dir" ]] || continue
    name=$(basename "$dir")
    num="${name#WP-}"
    [[ "$num" =~ ^[0-9]+$ ]] || continue
    total=$((total + 1))
    # Each folder is checked through its own card: WP-47/ and WP-047/ side by side are two folders.
    if [[ -f "${dir}${name}.md" ]]; then
      out=$(check_card "${dir}${name}.md")
    else
      out="WP-${num}: ❌ ${dir}${name}.md не найден — пропуск"
    fi
    echo "$out"
    if echo "$out" | grep -q "warn\|❌"; then
      warned=$((warned + 1))
    fi
  done
  echo ""
  echo "Итого: $total папок проверено, $warned с предупреждениями."
else
  WP_NUM="${MODE#WP-}"
  check_one "$WP_NUM"
fi
