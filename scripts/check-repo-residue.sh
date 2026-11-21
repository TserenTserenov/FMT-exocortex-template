#!/bin/bash
# routing: helper  skill=week-close  called-by=sonnet
# check-repo-residue.sh — find forgotten work in local working copies that no other check sees.
#
# Boundary with check-dirty-repos.sh (do not duplicate):
#   check-dirty-repos.sh — uncommitted files + unpushed commits of the CURRENT branch.
#   this script          — everything that stays invisible until the copy is deleted:
#                          stashes, branches with commits absent from every remote,
#                          orphaned objects (--deep), and data files living outside git;
#                          plus two machine-wide checks that catch the situation earlier —
#                          a second working copy of the same remote, and backup archives
#                          whose stated retention has expired.
#
# Why it exists: an abandoned clone can hold stashes reachable only through the refs/stash
# reflog (a plain mirror silently drops all but the newest), hundreds of orphaned commits,
# and database dumps or session files outside version control for months, and none of the
# other checks report any of it.
#
# Secret hygiene: report the CLASS and the PATH, never the contents. This script never
# reads a candidate data file.
#
# Usage:
#   bash check-repo-residue.sh              # fast scan (stashes, branches, data files)
#   bash check-repo-residue.sh --deep       # adds orphaned-object scan (slow: git fsck per repo)
#   bash check-repo-residue.sh --json       # machine-readable output
#
# Accepted findings live in <governance repo>/machine/repo-residue-accepted.tsv
# (repo<TAB>class<TAB>reason<TAB>review-date), so a decision made once does not resurface
# every week until its review date passes. The script never deletes or changes anything.
#
# Environment:
#   IWE_ROOT                workspace scanned two levels deep (default: the IWE workspace)
#   IWE_GOVERNANCE_REPO     governance repo name holding the accepted list (default: DS-strategy)
#   REPO_RESIDUE_ACCEPTED   explicit path of the accepted list (overrides the two above)
#   REPO_RESIDUE_BACKUPS    directory whose */RETENTION.yaml markers are checked (default: $HOME/backups)
#   REPO_RESIDUE_TODAY      date used for expiry comparisons, YYYY-MM-DD (default: today, UTC)
#
# Exit: 0 = nothing new, 2 = unaccepted residue found (week-close reads this), 1 = usage error.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
IWE_ROOT="${IWE_ROOT:-$WORKSPACE_DIR}"
# shellcheck source=lib/governance-repo-path.sh
. "$SCRIPT_DIR/lib/governance-repo-path.sh"
# The canonical accepted list, not the one in the caller's worktree: otherwise a decision
# made once would not survive the next run from another working copy.
ACCEPTED_FILE="${REPO_RESIDUE_ACCEPTED:-$(resolve_canonical_checkout)/machine/repo-residue-accepted.tsv}"
BACKUP_ROOT="${REPO_RESIDUE_BACKUPS:-$HOME/backups}"
TODAY="${REPO_RESIDUE_TODAY:-$(date -u +%F)}"   # overridable so the expiry branch is testable
DEEP=0
JSON_OUT=0
for arg in "$@"; do
  case "$arg" in
    --deep) DEEP=1 ;;
    --json) JSON_OUT=1 ;;
    -h|--help) sed -n '3,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# Files that must not live in a working copy unnoticed: data exports, access material,
# ad-hoc backups. Matched by name only — contents are never read.
DATA_PATTERNS='\.(dump|sql|session)$|(^|/)_backups/|(^|/)backup[^/]*\.(tar|gz|zip)$'

FINDINGS=0
declare -a JSON_ROWS=()

# Fields are trimmed: a stray space before the TAB would otherwise silently break
# suppression, with no way for the user to see why an accepted finding keeps coming back.
is_accepted() {
  local repo="$1" class="$2"
  [ -f "$ACCEPTED_FILE" ] || return 1
  awk -F'\t' -v r="$repo" -v c="$class" '
    { gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2) }
    $1==r && $2==c {found=1} END{exit !found}' "$ACCEPTED_FILE"
}

# Branch names may legally contain a double quote, and remote URLs may contain a backslash.
# Unescaped, either one breaks the WHOLE json document, not just its own row.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# Caller filters accepted findings (emit_findings) — no second check here.
report() {
  local repo="$1" class="$2" detail="$3"
  FINDINGS=$((FINDINGS + 1))
  if [ "$JSON_OUT" -eq 1 ]; then
    JSON_ROWS+=("{\"repo\":\"$(json_escape "$repo")\",\"class\":\"$(json_escape "$class")\",\"detail\":\"$(json_escape "$detail")\"}")
  else
    printf '  %-22s %s\n' "$class" "$detail"
  fi
}

# Prints "path<TAB>display-name" for every working copy under IWE_ROOT (two levels deep).
list_repos() {
  local dir parent base name
  for dir in "$IWE_ROOT"/*/ "$IWE_ROOT"/*/*/; do
    [ -d "$dir/.git" ] || continue
    parent=$(basename "$(dirname "$dir")")
    base=$(basename "$dir")
    [ "$parent" = "$(basename "$IWE_ROOT")" ] && name="$base" || name="$parent/$base"
    printf '%s\t%s\n' "${dir%/}" "$name"
  done
}

# Shared output path for every check: drops accepted findings BEFORE printing, so a scope
# whose findings are all accepted prints nothing at all.
emit_findings() {
  local scope="$1" out="$2"
  local header_shown=0 class detail
  while IFS='|' read -r class detail; do
    [ -z "$class" ] && continue
    is_accepted "$scope" "$class" && continue
    if [ "$header_shown" -eq 0 ] && [ "$JSON_OUT" -eq 0 ]; then
      echo ""
      echo "📁 $scope"
      header_shown=1
    fi
    report "$scope" "$class" "$detail"
  done <<< "$out"
}

scan_repo() {
  local dir="$1" name="$2"

  # Buffer findings so the header prints only when something is found.
  local out
  out=$(
    # A directory named .git is not proof of a readable repository. Without this gate every
    # git call below fails quietly and a corrupted copy reports "nothing found" — the worst
    # possible answer right before someone deletes it.
    if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
      echo "битый-репозиторий|служебный каталог есть, но git его не читает — содержимое проверить нельзя"
      exit 0
    fi

    stashes=$(git -C "$dir" stash list 2>/dev/null | wc -l | tr -d ' ')
    [ "$stashes" -gt 0 ] && echo "stash|$stashes отложенных наработок (видны только в журнале refs/stash)"

    # With no remote at all, --not --remotes excludes nothing and every branch looks unpublished.
    # One honest finding beats a wall of noise saying the same thing.
    if [ -z "$(git -C "$dir" remote 2>/dev/null)" ]; then
      echo "нет-серверной-копии|удалённых репозиториев нет — всё содержимое существует только здесь"
    else
      while IFS= read -r br; do
        [ -z "$br" ] && continue
        n=$(git -C "$dir" log --oneline "$br" --not --remotes 2>/dev/null | wc -l | tr -d ' ')
        [ "$n" -gt 0 ] && echo "ветка-без-публикации|$br: $n коммитов нет ни в одной серверной ветке"
      done < <(git -C "$dir" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)
    fi

    if [ "$DEEP" -eq 1 ]; then
      # Older stash entries surface here too: refs/stash points only at the newest one, so the
      # rest are unreachable by definition. Same object, two classes — not a double count bug.
      orphans=$(git -C "$dir" fsck --full --no-reflogs --unreachable 2>/dev/null | awk '$2=="commit"' | wc -l | tr -d ' ')
      [ "$orphans" -gt 0 ] && echo "оторванные-объекты|$orphans коммитов недостижимы из ссылок (обычный слепок их не берёт)"
    fi

    # Data outside version control. Read with -z: git quotes paths containing spaces or quotes
    # in the default format, and awk field-splitting would drop exactly those files.
    while IFS= read -r -d '' entry; do
      f="${entry:3}"
      printf '%s' "$f" | grep -qE "$DATA_PATTERNS" && echo "данные-вне-git|$f"
    done < <(git -C "$dir" status --porcelain=v1 -z --ignored=matching 2>/dev/null)
  )

  emit_findings "$name" "$out"
}

# A second working copy of the same repository tends to appear unnoticed, and the abandoned
# one then accumulates stashes and data. One remote URL owned by two directories is the
# signal, so it is checked machine-wide, not per repo. Same repository, different spelling
# (ssh vs https, with or without the .git suffix) must compare equal.
normalize_remote_url() {
  local url="$1" out
  if [[ "$url" == *://* ]]; then
    out="${url#*://}"        # strip scheme
    out="${out#*@}"          # strip user@ if present
  else
    out="${url#*@}"                                  # git@host:path
    out=$(printf '%s' "$out" | sed 's|:|/|')         # host:path -> host/path (first colon only)
  fi
  out="${out%.git}"
  out="${out%/}"
  printf '%s' "$out" | tr 'A-Z' 'a-z'
}

# A duplicate is not waste by default, and it is not legitimate by default either. Branch
# divergence is not the signal (duplicates are typically both on main with a clean tree).
# What decides each case: which copy is more current (the date below), and whether the OTHER
# copy has a stash, an unpublished branch, or data outside git — scan_repo reports those
# under the same repo name in the same run, so read them side by side with this finding.
# A copy with none of those and older than its sibling is a safe removal candidate; a copy
# with any of them is not, until that state is moved or explicitly accepted.
check_duplicate_clones() {
  local out
  out=$(
    while IFS=$'\t' read -r dir name; do
      url=$(git -C "$dir" remote get-url origin 2>/dev/null) || continue
      last_commit=$(git -C "$dir" log -1 --format=%cd --date=short 2>/dev/null || echo '?')
      [ -n "$url" ] && printf '%s\t%s (%s)\n' "$(normalize_remote_url "$url")" "$name" "$last_commit"
    done < <(list_repos) | sort | awk -F'\t' '
      { urls[$1] = urls[$1] ", " $2; count[$1]++ }
      END { for (u in urls) if (count[u] > 1) {
              sub(/^, /, "", urls[u])
              printf "дубль-рабочей-копии|%s: копий %d (%s)\n", u, count[u], urls[u]
            } }'
  )
  emit_findings "(машина)" "$out"
}

# Archives holding personal data must not outlive their stated retention: a dated marker turns
# "we will decide later" into a finding that resurfaces instead of silently ageing on disk.
check_expired_archives() {
  local marker dir_name expires personal line out=""
  for marker in "$BACKUP_ROOT"/*/RETENTION.yaml; do
    [ -f "$marker" ] || continue
    dir_name=$(basename "$(dirname "$marker")")
    expires=$(awk -F': *' '$1=="expires" {print $2; exit}' "$marker")
    personal=$(awk -F': *' '$1=="contains_personal_data" {print $2; exit}' "$marker")
    [ -n "$expires" ] || continue

    # String comparison only holds for ISO dates. A marker written as 31-01-2020 compared as
    # text looks like the future and would hide a years-old archive, so an unreadable date
    # becomes its own finding instead of a silent skip.
    if ! printf '%s' "$expires" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
      # Braces are required, not cosmetic: bash 3.2 (macOS system shell) treats the bytes of a
      # following non-ASCII character as part of the variable name and dies under set -u.
      line="нечитаемый-срок|$dir_name: срок записан как «${expires}», ожидается ГГГГ-ММ-ДД - проверить вручную"
    elif [[ "$TODAY" > "$expires" ]]; then
      line="просроченный-архив|$dir_name: срок хранения истёк ${expires}"
      [ "$personal" = "true" ] && line="$line, внутри персональные данные"
    else
      continue
    fi
    out="${out:+$out$'\n'}$line"
  done
  [ -n "$out" ] && emit_findings "(архивы)" "$out"
}

# An accepted finding is not a permanent "never resurfaces" decision: the 4th column carries a
# review date. This check reads the accepted list directly (not through emit_findings /
# is_accepted — these rows ARE the accepted list, surfacing them is the point) and reports
# every row whose review date has passed, is missing, or is unreadable.
check_expired_residue_decisions() {
  local repo class reason expires line out=""
  while IFS=$'\t' read -r repo class reason expires; do
    [ -z "$repo" ] && continue
    [[ "$repo" == \#* ]] && continue
    expires="${expires%$'\r'}"
    if [ -z "$expires" ]; then
      line="нет-срока|$repo/$class: срок повторного решения не задан — допишите дату ГГГГ-ММ-ДД в четвёртую колонку"
    elif ! printf '%s' "$expires" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
      line="нечитаемый-срок|$repo/$class: срок записан как «${expires}», ожидается ГГГГ-ММ-ДД"
    elif [[ "$TODAY" > "$expires" ]]; then
      line="просрочено|$repo/$class: срок решения истёк ${expires} — «${reason}»"
    else
      continue
    fi
    out="${out:+$out$'\n'}$line"
  done < "$ACCEPTED_FILE"
  if [ -n "$out" ]; then
    [ "$JSON_OUT" -eq 0 ] && echo "" && echo "⏰ ТРЕБУЕТ ПОВТОРНОГО РЕШЕНИЯ (срок в ${ACCEPTED_FILE} истёк или не задан)"
    while IFS='|' read -r class detail; do
      report "(принятые решения)" "$class" "$detail"
    done <<< "$out"
  fi
}

[ -f "$ACCEPTED_FILE" ] && check_expired_residue_decisions

[ "$JSON_OUT" -eq 0 ] && echo "🔍 Остаток в рабочих копиях (то, что исчезнет вместе с копией)"

while IFS=$'\t' read -r dir name; do
  scan_repo "$dir" "$name"
done < <(list_repos)

check_duplicate_clones
check_expired_archives

if [ "$JSON_OUT" -eq 1 ]; then
  printf '{"findings":%d,"items":[%s]}\n' "$FINDINGS" "$(IFS=,; echo "${JSON_ROWS[*]:-}")"
elif [ "$FINDINGS" -eq 0 ]; then
  echo ""
  echo "✅ Ничего нового: ни отложенных наработок, ни неопубликованных веток, ни данных вне git, ни дублей копий, ни просроченных архивов"
else
  echo ""
  echo "⚠️  Находок: ${FINDINGS}. Программа ничего не удаляет. По каждой находке — либо действие, либо строка в ${ACCEPTED_FILE} (репо<TAB>класс<TAB>причина<TAB>ГГГГ-ММ-ДД)"
  [ -f "$ACCEPTED_FILE" ] || echo "   Файла принятых решений ещё нет — создайте его с шапкой из seed/strategy/machine/repo-residue-accepted.tsv шаблона"
  [ "$DEEP" -eq 0 ] && echo "   Оторванные объекты не проверялись — для полной картины перед удалением копии запустите с --deep"
fi

[ "$FINDINGS" -eq 0 ] && exit 0 || exit 2
