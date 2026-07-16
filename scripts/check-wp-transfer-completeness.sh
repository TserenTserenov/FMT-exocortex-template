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

check_one() {
  local wp_num="$1"
  local wp_dir="$INBOX/WP-${wp_num}"
  local wp_file="$wp_dir/WP-${wp_num}.md"

  if [[ ! -f "$wp_file" ]]; then
    echo "WP-${wp_num}: ❌ $wp_file не найден — пропуск"
    return
  fi

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

if [[ "$MODE" == "--all" ]]; then
  total=0
  warned=0
  for dir in "$INBOX"/WP-*/; do
    [[ -d "$dir" ]] || continue
    name=$(basename "$dir")
    num="${name#WP-}"
    [[ "$num" =~ ^[0-9]+$ ]] || continue
    total=$((total + 1))
    out=$(check_one "$num")
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
