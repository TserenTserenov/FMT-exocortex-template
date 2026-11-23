#!/usr/bin/env bash
# wp-inbox.sh — inbound context mailbox of a WP (WP-5 Phase 69, DRR-f69-wp-inbound-mailbox).
#
# The WP owner writes the card inbox/WP-N/WP-N.md; other sessions write here:
# inbox/WP-N/INBOX.md (append-only). The owner folds entries into its phases
# on session open (wp-sync-bundle.sh signal) or on the phrase «актуализируй РП-N».
#
# Usage:
#   wp-inbox.sh add    --to WP-N --from "<WP or session>" --pointer "<path/link to full text>" --summary "<summary>"
#                      [--delivery-id ID]   Postman delivery id (WP-418 F10): an entry with the same id
#                      already in the box is not written again; the dedup check and the append run under
#                      one lock (kept in the checkout's git dir), so within one checkout the id is
#                      atomic with the effect; copies on different hosts may repeat it until they sync.
#                      stdout: «И-N записана в …» (new) or «И-N уже записана (доставка ID) в …» (duplicate).
#   wp-inbox.sh list   --wp WP-N [--all]       «новое» entries (with --all also «учтено»)
#   wp-inbox.sh count  --wp WP-N               number of «новое» entries
#   wp-inbox.sh digest --wp WP-N               fingerprint of «новое» entries (empty if none)
#   wp-inbox.sh mark   --wp WP-N --id K --by "<who/what processed it>"   «новое» → «учтено», idempotent
#   wp-inbox.sh pending                        every WP with «новое» entries, oldest first: «WP-N<TAB>count<TAB>oldest date»
#   wp-inbox.sh check-text [--wp WP-N]         mailbox text on stdin; prints the «новое» headers
#                                              (with --wp also the refusal text on stderr)
#                                              (WP-503 Phase 110: archive scripts and git hooks refuse to
#                                              archive a WP while this finds any). Exit 0 none · 1 found ·
#                                              2 unreadable input or an entry header it cannot parse.
# Common flag: --repo DIR (default $IWE_WORKSPACE/$IWE_GOVERNANCE_REPO).
# Read commands (list, count, digest, pending) also take --rev REF: read the
# mailbox as committed at REF (e.g. origin/main after a fetch) instead of the
# working tree, which lags behind origin while the canonical checkout is frozen.
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
[[ -n "$cmd" ]] || die "команда не указана (add|list|count|digest|mark|pending)"
shift

to="" wp="" from="" pointer="" summary="" id="" by="" rev="" all=0 delivery_id=""
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
    --delivery-id) delivery_id="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --rev) rev="${2:-}"; shift 2 ;;
    --all) all=1; shift ;;
    *) die "неизвестный флаг: $1" ;;
  esac
done

if [[ -n "$rev" ]]; then
  case "$cmd" in
    add|mark) die "--rev только для чтения (list|count|digest|pending): $cmd пишет в рабочую копию" ;;
  esac
  git -C "$repo" rev-parse --verify --quiet "$rev^{commit}" >/dev/null \
    || die "ревизия '$rev' не найдена в $repo (для origin/main сначала git fetch)" 1
fi

# Mailbox text of WP number $1: from the working tree, or as committed at --rev.
box_text() {
  local rel="inbox/WP-$1/INBOX.md"
  if [[ -n "$rev" ]]; then
    git -C "$repo" cat-file -e "$rev:$rel" 2>/dev/null || return 0
    git -C "$repo" show "$rev:$rel"
  elif [[ -f "$repo/$rel" ]]; then
    cat "$repo/$rel"
  fi
}

# The one place that knows the entry header format. Reads mailbox text on stdin
# and prints the entries with status $1: header plus body up to the next header.
# Byte matching (LC_ALL=C): under a UTF-8 locale macOS awk aborts on an invalid
# byte and drops every entry after it; the patterns are literal UTF-8 bytes.
filter_status() {
  LC_ALL=C awk -v want="$1" '/^## И-[0-9]+ · / { p = ($0 ~ (" · " want "$")) } p'
}

# Entries with status $2 of WP number $1 as one stream.
entries_with_status() {
  box_text "$1" | filter_status "$2"
}

# check-text: mailbox text on stdin. A header that ends in neither status is
# reported as unparseable (exit 2): an unknown status must not pass as "no new entries".
# With --wp N the refusal to archive is explained on stderr; every caller
# (archive scripts, git hooks) relays this one text.
check_text() {
  local who="${wp:+РП-$(normalize_wp "$wp")}"
  who="${who:-РП}"
  local text bad entries fresh
  text=$(cat) || die "не удалось прочитать текст ящика из stdin" 2
  bad=$(printf '%s\n' "$text" | LC_ALL=C grep -E '^## И-' | LC_ALL=C grep -vE '^## И-[0-9]+ · [0-9]{4}-[0-9]{2}-[0-9]{2} · .* · (новое|учтено)$' || true)
  if [[ -n "$bad" ]]; then
    printf 'wp-inbox: %s нельзя переносить в архив: в ящике заголовок записи без статуса «новое» или «учтено»:\n%s\n' "$who" "$bad" >&2
    printf '   Статус записи меняет только wp-inbox.sh mark; заголовок правили руками. Верните заголовок к виду «## И-K · дата · из … · новое» и разберите запись.\n' >&2
    exit 2
  fi
  entries=$(printf '%s\n' "$text" | filter_status "новое") || die "разбор текста ящика не удался" 2
  fresh=$(printf '%s\n' "$entries" | LC_ALL=C grep -E '^## И-[0-9]+ · ' || true)
  [[ -z "$fresh" ]] && exit 0
  printf '%s\n' "$fresh"
  if [[ -n "$wp" ]]; then
    {
      printf 'wp-inbox: %s нельзя переносить в архив: в ящике входящих %s записей «новое» (заголовки выше).\n' "$who" "$(printf '%s\n' "$fresh" | grep -c .)"
      printf '   Пройти проверку можно только двумя способами (решение пилота, РП-503 Ф110):\n'
      printf '   1) перенести выжимку и указатель записи в «Осталось» карточки;\n'
      printf '   2) получить согласие пилота на «учтено».\n'
      printf '   Затем: wp-inbox.sh mark --wp %s --id K --by "<перенесено в «Осталось» | учтено с согласия пилота: как>".\n' "$(normalize_wp "$wp")"
      printf '   Пока решения нет, РП остаётся в работе: закрывается сессия, а не РП.\n'
    } >&2
  fi
  exit 1
}

if [[ "$cmd" == "check-text" ]]; then
  check_text
fi

if [[ "$cmd" == "pending" ]]; then
  if [[ -n "$rev" ]]; then
    boxes=$(git -C "$repo" ls-tree -r --name-only "$rev" -- inbox | grep -E '^inbox/WP-[0-9]+/INBOX\.md$' || true)
  else
    boxes=$(cd "$repo" && find inbox -mindepth 2 -maxdepth 2 -path 'inbox/WP-*/INBOX.md' 2>/dev/null || true)
  fi
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    num=$(printf '%s' "$rel" | sed -E 's|^inbox/WP-([0-9]+)/INBOX\.md$|\1|')
    [[ "$num" =~ ^[0-9]+$ ]] || continue
    headers=$(entries_with_status "$num" "новое" | grep -E '^## И-[0-9]+ · ' || true)
    [[ -n "$headers" ]] || continue
    oldest=$(printf '%s\n' "$headers" | sed -E 's/^## И-[0-9]+ · ([0-9-]+) · .*/\1/' | sort | head -1)
    printf '%s\t%s\t%s\n' "$oldest" "$num" "$(printf '%s\n' "$headers" | wc -l | tr -d ' ')"
  done <<< "$boxes" | sort -k1,1 -k2,2n | awk -F '\t' '{ printf "WP-%s\t%s\t%s\n", $2, $3, $1 }'
  exit 0
fi

target="${to:-$wp}"
[[ -n "$target" ]] || die "укажите --to (add) или --wp (остальные команды)"
n=$(normalize_wp "$target")
dir="$repo/inbox/WP-$n"
card="$dir/WP-$n.md"
box="$dir/INBOX.md"

case "$cmd" in
  add)
    [[ -n "$from" && -n "$pointer" && -n "$summary" ]] || die "add требует --from, --pointer и --summary"
    if [[ -n "$delivery_id" ]]; then
      [[ "$delivery_id" =~ ^[A-Za-z0-9._:-]{1,80}$ ]] || die "идентификатор доставки: только латиница, цифры и . _ : -, до 80 знаков"
    fi
    if [[ ! -f "$card" ]]; then
      echo "wp-inbox: у РП-$n нет карточки $card (закрыт или не заведён) — запись не создана; для закрытого РП используйте $repo/inbox/backlog-with-triggers.md" >&2
      exit 1
    fi
    # The lock belongs to the checkout, not to TMPDIR (WP-418 F10): writers with
    # different TMPDIR over one checkout must exclude each other. Inside the git
    # dir it is never committed; outside git it sits next to the mailbox. The
    # holder's PID is kept inside: a lock whose holder is gone (killed past its
    # EXIT trap) is removed, a lock without a PID is removed after 60 s.
    lock=$(git -C "$repo" rev-parse --git-path "wp-inbox-$n.lock" 2>/dev/null) || lock="$dir/.INBOX.lock"
    [[ "$lock" = /* ]] || lock="$repo/$lock"
    tries=0
    until mkdir "$lock" 2>/dev/null; do
      holder=$(cat "$lock/pid" 2>/dev/null || true)
      if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null \
         || [[ -z "$holder" && -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
        # Re-read just before removing: never drop a lock a new holder took meanwhile.
        if [[ "$(cat "$lock/pid" 2>/dev/null || true)" == "$holder" ]]; then
          echo "wp-inbox: снимаю брошенную блокировку ящика РП-$n${holder:+ (процесс ${holder} завершён)}" >&2
          rm -f "$lock/pid"
          rmdir "$lock" 2>/dev/null || true
          continue
        fi
      fi
      tries=$((tries + 1))
      [[ $tries -le 50 ]] || die "ящик РП-$n занят другой записью более 5 с" 1
      sleep 0.1
    done
    echo "$$" > "$lock/pid"
    trap 'rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null || true' EXIT
    last=0
    if [[ -f "$box" ]]; then
      last=$(grep -E '^## И-[0-9]+ · ' "$box" | sed -E 's/^## И-([0-9]+) · .*/\1/' | sort -n | tail -1 || true)
      last="${last:-0}"
    else
      printf '# Входящие РП-%s\n\n> Только дописывание. Статус записи меняет скрипт wp-inbox.sh (mark), не правка текста.\n' "$n" > "$box"
    fi
    if [[ -n "$delivery_id" && -f "$box" ]]; then
      # A «Доставка:» line above the first header (hand edit) has no entry number and is ignored.
      dup=$(LC_ALL=C awk -v want="Доставка: $delivery_id" '
        /^## И-[0-9]+ · / { n = $2; sub(/^И-/, "", n) }
        $0 == want { print n; exit }' "$box")
      if [[ -n "$dup" ]]; then
        echo "И-$dup уже записана (доставка $delivery_id) в $box"
        exit 0
      fi
    fi
    next=$((last + 1))
    {
      printf '\n## И-%s · %s · из %s · новое\n' "$next" "$(date +%Y-%m-%d)" "$(one_line "$from")"
      printf 'Указатель: %s\n' "$(one_line "$pointer")"
      printf 'Выжимка: %s\n' "$(one_line "$summary")"
      [[ -z "$delivery_id" ]] || printf 'Доставка: %s\n' "$delivery_id"
    } >> "$box"
    echo "И-$next записана в $box"
    ;;
  list)
    if [[ "$all" -eq 1 ]]; then
      box_text "$n" | LC_ALL=C awk '/^## И-[0-9]+ · /{p=1} p'
    else
      entries_with_status "$n" "новое"
    fi
    ;;
  count)
    entries_with_status "$n" "новое" | grep -c -E '^## И-[0-9]+ · ' || true
    ;;
  digest)
    out=$(entries_with_status "$n" "новое")
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
