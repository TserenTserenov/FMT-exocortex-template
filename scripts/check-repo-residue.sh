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
#                                           # and looks for data files inside dependency dirs too
#   bash check-repo-residue.sh --json       # machine-readable output
#
# Data files are looked for among ALL files git does not track, including those inside
# untracked or ignored directories. The fast scan does not descend into dependency and cache
# directories (DEPENDENCY_DIRS below: node_modules, .venv, ...) — they hold thousands of files
# and no hand-made exports; --deep descends into them as well.
#
# Accepted findings live in <governance repo>/machine/repo-residue-accepted.tsv
# (repo<TAB>class<TAB>item<TAB>reason<TAB>review-date). The item is the first word(s) of the
# finding line — branch name, stash id, file path, archive name — so accepting one finding
# never hides a NEW finding of the same class; "*" hides the whole class on purpose. Until its
# review date the finding does not resurface. Rows with fewer than five columns (the earlier
# format without an item) hide nothing and are reported for migration. The script never
# deletes or changes anything.
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
    -h|--help) sed -n '3,48p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# Files that must not live in a working copy unnoticed: data exports, access material,
# ad-hoc backups. Matched by name only — contents are never read.
DATA_PATTERNS='\.(dump|sql|session)$|(^|/)_backups/|(^|/)backup[^/]*\.(tar|gz|zip)$'

# Dependency and cache directories the fast scan does not enter (any depth). They are rebuilt
# by package managers, can hold hundreds of thousands of files, and listing them would make the
# weekly run slow for no finding. --deep enters them: a full picture before deleting a copy.
DEPENDENCY_DIRS="node_modules .venv venv .tox __pycache__ .mypy_cache .pytest_cache .ruff_cache .gradle .terraform .next"

# Internal field separator of a finding: class, item, detail. Not "|" or TAB — both may occur in
# a file name, and the item must survive intact to be compared with the accepted list.
SEP=$'\037'

FINDINGS=0
declare -a JSON_ROWS=()

# An accepted row hides exactly one finding: same repo, same class, same item. "*" in the item
# column hides the whole class deliberately. Rows with fewer than five columns (the format
# before items existed) hide nothing — check_expired_residue_decisions reports them instead.
# Fields are trimmed: a stray space before the TAB would otherwise silently break
# suppression, with no way for the user to see why an accepted finding keeps coming back.
is_accepted() {
  local repo="$1" class="$2" item="$3"
  [ -f "$ACCEPTED_FILE" ] || return 1
  awk -F'\t' -v r="$repo" -v c="$class" -v i="$item" '
    { for (k = 1; k <= NF; k++) gsub(/^[ \t\r]+|[ \t\r]+$/, "", $k) }
    NF >= 5 && $1==r && $2==c && ($3==i || $3=="*") {found=1} END{exit !found}' "$ACCEPTED_FILE"
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
  local repo="$1" class="$2" item="$3" detail="$4"
  FINDINGS=$((FINDINGS + 1))
  if [ "$JSON_OUT" -eq 1 ]; then
    JSON_ROWS+=("{\"repo\":\"$(json_escape "$repo")\",\"class\":\"$(json_escape "$class")\",\"item\":\"$(json_escape "$item")\",\"detail\":\"$(json_escape "$detail")\"}")
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
  local header_shown=0 class item detail
  while IFS="$SEP" read -r class item detail; do
    [ -z "$class" ] && continue
    is_accepted "$scope" "$class" "$item" && continue
    if [ "$header_shown" -eq 0 ] && [ "$JSON_OUT" -eq 0 ]; then
      echo ""
      echo "📁 $scope"
      header_shown=1
    fi
    report "$scope" "$class" "$item" "$detail"
  done <<< "$out"
}

# finding <class> <item> <detail> — one line for emit_findings. The printed detail starts with
# the item, so the user can copy it into the accepted list as it is.
finding() {
  printf '%s%s%s%s%s\n' "$1" "$SEP" "$2" "$SEP" "$3"
}

# Every file git does not track, NUL-separated, including files inside untracked and ignored
# directories (plain `git status` prints only such a directory's name, which hides the files).
# No ignore rules are applied on purpose: an ignored dump is exactly what this check is for.
# Nested repositories come out as "dir/" and are not entered.
list_untracked_files() {
  local dir="$1" d
  local -a skip=()
  if [ "$DEEP" -eq 0 ]; then
    for d in $DEPENDENCY_DIRS; do skip+=("--exclude=$d/"); done
  fi
  git -C "$dir" ls-files --others -z ${skip[@]+"${skip[@]}"} 2>/dev/null
}

scan_repo() {
  local dir="$1" name="$2"

  # Buffer findings so the header prints only when something is found.
  local out
  out=$(
    # A directory named .git is not proof of a readable repository. Without this gate every
    # git call below fails quietly and a corrupted copy reports "nothing found" — the worst
    # possible answer right before someone deletes it.
    # Items: "-" for a finding a repository can have only once; otherwise the thing itself.
    if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
      finding "битый-репозиторий" "-" "служебный каталог есть, но git его не читает — содержимое проверить нельзя"
      exit 0
    fi

    # One finding per stash entry, keyed by its commit id: stash@{N} numbers shift with every
    # new stash, and two entries may share a message.
    while IFS=$'\t' read -r ref sha subject; do
      [ -z "$sha" ] && continue
      sha="${sha:0:12}"
      finding "stash" "$sha" "$sha: $ref «${subject}» (видна только в журнале refs/stash)"
    done < <(git -C "$dir" stash list --format='%gd%x09%H%x09%gs' 2>/dev/null)

    # With no remote at all, --not --remotes excludes nothing and every branch looks unpublished.
    # One honest finding beats a wall of noise saying the same thing.
    if [ -z "$(git -C "$dir" remote 2>/dev/null)" ]; then
      finding "нет-серверной-копии" "-" "удалённых репозиториев нет — всё содержимое существует только здесь"
    else
      while IFS= read -r br; do
        [ -z "$br" ] && continue
        n=$(git -C "$dir" log --oneline "$br" --not --remotes 2>/dev/null | wc -l | tr -d ' ')
        [ "$n" -gt 0 ] && finding "ветка-без-публикации" "$br" "$br: $n коммитов нет ни в одной серверной ветке"
      done < <(git -C "$dir" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)
    fi

    if [ "$DEEP" -eq 1 ]; then
      # Older stash entries surface here too: refs/stash points only at the newest one, so the
      # rest are unreachable by definition. Same object, two classes — not a double count bug.
      # The item is the count: there is no per-commit name, and an acceptance of "these N"
      # must not hide new orphans, so any change of the number brings the finding back.
      orphans=$(git -C "$dir" fsck --full --no-reflogs --unreachable 2>/dev/null | awk '$2=="commit"' | wc -l | tr -d ' ')
      [ "$orphans" -gt 0 ] && finding "оторванные-объекты" "$orphans" "$orphans коммитов недостижимы из ссылок (обычный слепок их не берёт)"
    fi

    # Data outside version control. NUL-separated listing: git quotes paths containing spaces or
    # quotes otherwise. One grep for the whole repo, not one per file. A _backups directory is
    # reported once, not file by file.
    list_untracked_files "$dir" | tr '\0' '\n' | grep -E "$DATA_PATTERNS" \
      | sed -E 's#^((.*/)?_backups/).*#\1#' | LC_ALL=C sort -u \
      | while IFS= read -r f; do
          [ -n "$f" ] && finding "данные-вне-git" "$f" "$f"
        done
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
      [ -n "$url" ] && printf '%s\t%s\t%s\n' "$(normalize_remote_url "$url")" "$name" "$last_commit"
    done < <(list_repos) | LC_ALL=C sort | awk -F'\t' -v sep="$SEP" '
      { names[$1] = names[$1] ", " $2; dates[$1] = dates[$1] ", " $2 " " $3; count[$1]++ }
      END { for (u in names) if (count[u] > 1) {
              sub(/^, /, "", names[u]); sub(/^, /, "", dates[u])
              # The item lists the copies: a third copy changes it, so an accepted pair does
              # not hide a new duplicate.
              item = u ": " names[u]
              printf "дубль-рабочей-копии%s%s%s%s — копий %d, последний коммит: %s\n", sep, item, sep, item, count[u], dates[u]
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
      line=$(finding "нечитаемый-срок" "$dir_name" "$dir_name: срок записан как «${expires}», ожидается ГГГГ-ММ-ДД - проверить вручную")
    elif [[ "$TODAY" > "$expires" ]]; then
      line=$(finding "просроченный-архив" "$dir_name" "$dir_name: срок хранения истёк ${expires}")
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
# every row whose review date has passed, is missing, or is unreadable — and every row in the
# earlier four-column format (no item), which no longer hides anything until it is migrated.
# Parsed in awk, not `read`: TAB is IFS whitespace there, so an empty column would silently
# shift every column after it.
check_expired_residue_decisions() {
  local out class item detail
  out=$(awk -F'\t' -v today="$TODAY" -v sep="$SEP" '
    { for (k = 1; k <= NF; k++) gsub(/^[ \t\r]+|[ \t\r]+$/, "", $k) }
    $1 == "" || $1 ~ /^#/ { next }
    NF < 5 {
      key = $1 "/" $2
      printf "старый-формат%s%s%s%s: колонок %d, нужно пять (репо, класс, что, причина, срок) — строка ничего не скрывает; впишите третьей колонкой, что именно принято (имя ветки, путь, ...), или * для всего класса\n", sep, key, sep, key, NF
      next
    }
    {
      key = $1 "/" $2 "/" $3
      if ($5 == "")
        printf "нет-срока%s%s%s%s: срок повторного решения не задан — допишите дату ГГГГ-ММ-ДД в пятую колонку\n", sep, key, sep, key
      else if ($5 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/)
        printf "нечитаемый-срок%s%s%s%s: срок записан как «%s», ожидается ГГГГ-ММ-ДД\n", sep, key, sep, key, $5
      else if (today > $5)
        printf "просрочено%s%s%s%s: срок решения истёк %s — «%s»\n", sep, key, sep, key, $5, $4
    }' "$ACCEPTED_FILE")
  if [ -n "$out" ]; then
    [ "$JSON_OUT" -eq 0 ] && echo "" && echo "⏰ ТРЕБУЕТ ПОВТОРНОГО РЕШЕНИЯ (срок в ${ACCEPTED_FILE} истёк, не задан или строка старого формата)"
    while IFS="$SEP" read -r class item detail; do
      report "(принятые решения)" "$class" "$item" "$detail"
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
  echo "⚠️  Находок: ${FINDINGS}. Программа ничего не удаляет. По каждой находке — либо действие, либо строка в ${ACCEPTED_FILE} (репо<TAB>класс<TAB>что<TAB>причина<TAB>ГГГГ-ММ-ДД; «что» — начало строки находки до двоеточия: ветка, путь, id отложенной правки; «-» у находки, которая бывает у репо одна)"
  [ -f "$ACCEPTED_FILE" ] || echo "   Файла принятых решений ещё нет — создайте его с шапкой из seed/strategy/machine/repo-residue-accepted.tsv шаблона"
  [ "$DEEP" -eq 0 ] && echo "   Оторванные объекты не проверялись — для полной картины перед удалением копии запустите с --deep"
fi

[ "$FINDINGS" -eq 0 ] && exit 0 || exit 2
