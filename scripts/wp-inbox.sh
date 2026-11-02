#!/usr/bin/env bash
# wp-inbox.sh — inbound context mailbox of a WP (WP-5 Phase 69, DRR-f69-wp-inbound-mailbox).
#
# The WP owner writes the card inbox/WP-N/WP-N.md; other sessions write here:
# inbox/WP-N/INBOX.md (append-only). The owner folds entries into its phases
# on session open (wp-sync-bundle.sh signal) or on the phrase «актуализируй РП-N».
#
# Usage:
#   wp-inbox.sh add    --to WP-N --from "<WP or session>" --pointer "<path/link to full text>" --summary "<summary>"
#   wp-inbox.sh list   --wp WP-N [--all]       «новое» entries (with --all also «учтено»)
#   wp-inbox.sh count  --wp WP-N               number of «новое» entries
#   wp-inbox.sh digest --wp WP-N               fingerprint of «новое» entries (empty if none)
#   wp-inbox.sh mark   --wp WP-N --id K --by "<who/what processed it>"   «новое» → «учтено», idempotent
# Common flag: --repo DIR (default $IWE_WORKSPACE/$IWE_GOVERNANCE_REPO).
#
# Exit codes: 0 success · 1 refused by condition (no card, no entry) · 2 usage error.
# Compatible: bash 3.2+

set -euo pipefail

die() { echo "wp-inbox: $*" >&2; exit "${2:-2}"; }

normalize_wp() {
  local n="${1#WP-}"
  n="${n#РП-}"
  [[ "$n" =~ ^[0-9]+$ ]] || die "номер РП не распознан: '$1'"
  echo "$n"
}

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1
  fi
}

# Single line, no newlines and no entry headers: otherwise summary text
# could forge an entry boundary (a «## И-…» line inside the body).
one_line() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | sed -E 's/  +/ /g; s/^ +//; s/ +$//; s/^## /# /'
}

cmd="${1:-}"
[[ -n "$cmd" ]] || die "команда не указана (add|list|count|digest|mark)"
shift

to="" wp="" from="" pointer="" summary="" id="" by="" all=0
repo="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to) to="${2:-}"; shift 2 ;;
    --wp) wp="${2:-}"; shift 2 ;;
    --from) from="${2:-}"; shift 2 ;;
    --pointer) pointer="${2:-}"; shift 2 ;;
    --summary) summary="${2:-}"; shift 2 ;;
    --id) id="${2:-}"; shift 2 ;;
    --by) by="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --all) all=1; shift ;;
    *) die "неизвестный флаг: $1" ;;
  esac
done

target="${to:-$wp}"
[[ -n "$target" ]] || die "укажите --to (add) или --wp (остальные команды)"
n=$(normalize_wp "$target")
dir="$repo/inbox/WP-$n"
card="$dir/WP-$n.md"
box="$dir/INBOX.md"

# «новое» entries as one stream: header plus body up to the next header.
entries_with_status() {
  [[ -f "$box" ]] || return 0
  awk -v want="$1" '/^## И-[0-9]+ · / { p = ($0 ~ (" · " want "$")) } p' "$box"
}

case "$cmd" in
  add)
    [[ -n "$from" && -n "$pointer" && -n "$summary" ]] || die "add требует --from, --pointer и --summary"
    if [[ ! -f "$card" ]]; then
      echo "wp-inbox: у РП-$n нет карточки $card (закрыт или не заведён) — запись не создана; для закрытого РП используйте $repo/inbox/backlog-with-triggers.md" >&2
      exit 1
    fi
    lock="${TMPDIR:-/tmp}/wp-inbox-$n.lock"
    tries=0
    until mkdir "$lock" 2>/dev/null; do
      tries=$((tries + 1))
      [[ $tries -le 50 ]] || die "ящик РП-$n занят другой записью более 5 с" 1
      sleep 0.1
    done
    trap 'rmdir "$lock" 2>/dev/null || true' EXIT
    last=0
    if [[ -f "$box" ]]; then
      last=$(grep -E '^## И-[0-9]+ · ' "$box" | sed -E 's/^## И-([0-9]+) · .*/\1/' | sort -n | tail -1 || true)
      last="${last:-0}"
    else
      printf '# Входящие РП-%s\n\n> Только дописывание. Статус записи меняет скрипт wp-inbox.sh (mark), не правка текста.\n' "$n" > "$box"
    fi
    next=$((last + 1))
    {
      printf '\n## И-%s · %s · из %s · новое\n' "$next" "$(date +%Y-%m-%d)" "$(one_line "$from")"
      printf 'Указатель: %s\n' "$(one_line "$pointer")"
      printf 'Выжимка: %s\n' "$(one_line "$summary")"
    } >> "$box"
    echo "И-$next записана в $box"
    ;;
  list)
    if [[ "$all" -eq 1 ]]; then
      [[ ! -f "$box" ]] || awk '/^## И-[0-9]+ · /{p=1} p' "$box"
    else
      entries_with_status "новое"
    fi
    ;;
  count)
    entries_with_status "новое" | grep -c -E '^## И-[0-9]+ · ' || true
    ;;
  digest)
    out=$(entries_with_status "новое")
    [[ -z "$out" ]] || printf '%s\n' "$out" | sha256_stdin
    ;;
  mark)
    [[ "$id" =~ ^[0-9]+$ && -n "$by" ]] || die "mark требует числовой --id и --by"
    [[ -f "$box" ]] || die "у РП-$n нет ящика входящих" 1
    header=$(grep -E "^## И-$id · " "$box" || true)
    [[ -n "$header" ]] || die "в ящике РП-$n нет записи И-$id" 1
    if [[ "$header" == *" · учтено" ]]; then
      echo "И-$id уже учтена"
      exit 0
    fi
    tmp="$box.tmp.$$"
    awk -v id="$id" -v by="$(one_line "$by")" '
      $0 ~ ("^## И-" id " · ") { sub(/ · новое$/, " · учтено"); print; print "Учтено: " by; next }
      { print }
    ' "$box" > "$tmp" && mv "$tmp" "$box"
    echo "И-$id помечена «учтено»"
    ;;
  *) die "неизвестная команда: $cmd" ;;
esac
