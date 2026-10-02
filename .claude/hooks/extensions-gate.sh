#!/bin/bash
# Extensions Gate Hook
# Event: PreToolUse (matcher: Edit, Write). Это блокирующий guardrail для двух
# структурированных file tools, а не tool-independent security boundary:
# произвольный Bash не разбирается (issue #528), что прямо раскрыто в CLAUDE.md.
# Блокирует прямое редактирование .claude/skills/, memory/protocol-*.md и
# update-manifest.json (манифест определяет, какие скиллы платформенные, —
# правка одного файла отключала бы гейт целиком).
#
# Инвариант (отчёт Константина 14.08.2026, WP-7 Ф71): разрешение выдаётся
# только при ДОКАЗАННО успешной проверке; отсутствие или отказ любого
# инструмента (jq, python3, битый манифест) — блокировка, не пропуск.
# До этого гейт был fail-open: пустой вывод `jq ... 2>/dev/null` читался как
# «скилла нет в манифесте» → разрешение; путь с «..» давал имя чужого скилла;
# симлинк из своей папки на платформенный файл проходил.
#
# Исключения:
#   - FMT-exocortex-template (шаблон — всегда разрешён, кроме манифеста)
#   - author_mode: true в params.yaml (автор шаблона — source-of-truth в IWE,
#     пропагация в FMT через template-sync.sh)
#   - issue #311: новая директория .claude/skills/<name>/, которой нет в
#     update-manifest.json — свой навык, update.sh её не тронет. extend/SKILL.md
#     документирует ровно этот путь как штатный.
#   - issue #872: правка платформенного .claude/skills/<name>/SKILL.md, весь
#     эффект которой лежит ВНУТРИ единственного блока между строками
#     <!-- USER-SPACE --> и <!-- /USER-SPACE --> (update.sh сохраняет этот блок
#     при обновлении; scripts/add-skill-markers.sh добавляет его в L1-скиллы).
#     Решение принимается по ИНВАРИАНТУ результирующего документа, не по
#     old_string/new_string: считаем содержимое файла ПОСЛЕ вызова и требуем
#     побайтово те же маркеры, тот же текст до открывающего и после закрывающего
#     маркера. Исключение относится ТОЛЬКО к обычному существующему файлу с
#     физическим путём <workspace>/.claude/skills/<имя>/SKILL.md; для любого
#     другого файла (другие хуки, settings, CLAUDE.md, соседние файлы скилла,
#     memory/protocol-*) оно ничего не меняет: прежнее решение хука сохраняется
#     как есть (в частности, хук по-прежнему не закрывает .claude/hooks/*).
#     Любая ошибка разбора/чтения = блок (fail-closed); нет python3 — исключение
#     не действует.
#     Принадлежность скилла к платформенному слою доказана ПОРЯДКОМ веток, а не
#     маркерами: исключение 3 (#311) раньше выпускает любой скилл, чей каталог
#     отсутствует в прочитанном манифесте, поэтому сюда доходят только скиллы,
#     записанные в манифесте. Остаточный риск: проверка содержимого и сама запись
#     инструментом не атомарны (гонка при подмене файла между ними), а хук не может
#     передать инструменту проверенный inode — он остаётся guardrail от случайной
#     правки, а не границей безопасности (см. CLAUDE.md §9, Extensions Gate).

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
WHY_MARKERS = "в файле нет ровно одной корректной пары маркеров USER-SPACE"


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
        raise Deny("маркеры USER-SPACE стоят в неправильном порядке")
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
        raise Deny("путь файла должен быть абсолютным")
    if not real.startswith(ws + "/"):
        raise Deny("файл вне рабочего каталога")
    parts = real[len(ws) + 1:].split("/")
    if (len(parts) != 4 or parts[0] != ".claude" or parts[1] != "skills"
            or parts[2] in ("", ".", "..") or parts[3] != "SKILL.md"):
        raise Deny("исключение действует только для .claude/skills/имя/SKILL.md")
    comps = raw.replace("\\", "/").split("/")
    if comps[-4:] != parts:
        raise Deny("путь не канонический: симлинк, другой регистр букв или лишние сегменты")
    head = "/".join(comps[:-4]) or "/"
    if native_realpath(head) != ws:
        raise Deny("путь не канонический: префикс не совпадает с рабочим каталогом")
    base = "" if head == "/" else head
    for i in range(1, 4):
        if stat.S_ISLNK(os.lstat(base + "/" + "/".join(parts[:i])).st_mode):
            raise Deny("каталог на пути к SKILL.md является симлинком")


def read_original(raw):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        fd = os.open(raw, flags)
    except OSError:
        raise Deny("SKILL.md не существует или это симлинк: создание файла через исключение запрещено")
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise Deny("SKILL.md не является обычным файлом")
        if st.st_nlink != 1:
            raise Deny("SKILL.md имеет жёсткие ссылки")
        if st.st_size > MAX_BYTES:
            raise Deny("SKILL.md слишком большой для проверки")
        with os.fdopen(fd, "rb", closefd=False) as fh:
            data = fh.read(MAX_BYTES + 1)
    finally:
        os.close(fd)
    if len(data) > MAX_BYTES:
        raise Deny("SKILL.md слишком большой для проверки")
    data.decode("utf-8")  # strict: a non-UTF-8 file is not something the tools round-trip
    return data


def apply_edit(original, search, repl, replace_all):
    return original.replace(search, repl) if replace_all else original.replace(search, repl, 1)


def simulate(payload, original):
    """Return the candidate resulting documents (all must satisfy the invariant)."""
    tool = payload.get("tool_name")
    ti = payload.get("tool_input")
    if not isinstance(ti, dict):
        raise Deny("нет tool_input")
    if tool not in ("Edit", "Write"):
        raise Deny("исключение действует только для Edit и Write")
    if tool == "Write":
        if "old_string" in ti or not isinstance(ti.get("content"), str):
            raise Deny("некорректный вызов Write")
        return [ti["content"].encode("utf-8")]
    if "content" in ti or not isinstance(ti.get("old_string"), str) \
            or not isinstance(ti.get("new_string"), str):
        raise Deny("некорректный вызов Edit")
    replace_all = ti.get("replace_all", False)
    if not isinstance(replace_all, bool):
        raise Deny("некорректный replace_all")
    old = ti["old_string"].encode("utf-8")
    new = ti["new_string"].encode("utf-8")
    if not old:
        raise Deny("пустой old_string")
    count = original.count(old)
    if count == 0:
        raise Deny("old_string не найден в файле")
    if count > 1 and not replace_all:
        raise Deny("old_string встречается больше одного раза")
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
        raise Deny("payload не объект")
    tool_input = payload.get("tool_input")
    # The shell layer read the path through jq and command substitution; the
    # path judged here must be byte-for-byte the one the tool will open.
    if not isinstance(tool_input, dict) or tool_input.get("file_path") != raw:
        raise Deny("путь в вызове не совпадает с проверенным путём")
    check_path(ws, real, raw)
    original = read_original(raw)
    pre, open_line, _block, close_line, post = parse(original)
    for result in simulate(payload, original):
        # The invariant on the RESULT: still exactly one well-formed pair, the
        # marker lines and everything outside them byte-identical. Only the
        # block between the markers may differ.
        r_pre, r_open, _r_block, r_close, r_post = parse(result)
        if (r_pre, r_open, r_close, r_post) != (pre, open_line, close_line, post):
            raise Deny("правка выходит за пределы блока USER-SPACE или меняет сами маркеры")


try:
    main()
    out = "ALLOW"
except Deny as exc:
    out = "DENY:" + str(exc)
except Exception:
    out = "DENY:не удалось разобрать файл или вызов — блокирую"
sys.stdout.buffer.write(out.encode("utf-8"))
PYEOF

INPUT=$(cat)

# Fail-closed parsing: no jq → we cannot classify the path at all.
if ! command -v jq >/dev/null 2>&1; then
  block "jq не найден — гейт не может проверить путь. Установи jq (brew install jq / apt install jq) и повтори."
fi
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
if [ -n "$INPUT" ] && [ -z "$FILE_PATH" ]; then
  # Matcher is Edit|Write: a payload without file_path is an anomaly, not a norm.
  block "не удалось извлечь путь файла из вызова (битый payload) — правка не классифицируется, блокирую."
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

# Resolve symlinks: симлинк из своей папки скилла на платформенный файл обязан
# классифицироваться по ЦЕЛИ, не по имени симлинка. Без резолвера защита молча
# исчезает — поэтому его отказ = блок, не откат к сырому пути.
REAL_PATH=$(real_path "$FILE_PATH")
if [ -z "$REAL_PATH" ]; then
  block "python3 недоступен или не смог нормализовать путь — без этого не проверить симлинки, блокирую."
fi

# Gate owns only the project workspace. A global ~/.claude skill, a sibling
# workspace and any other external path are user territory that update.sh can
# neither overwrite nor protect. Compare physical roots so symlink and prefix
# collisions cannot smuggle an internal platform file through this boundary.
WORKSPACE_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
WORKSPACE_REAL=$(real_path "$WORKSPACE_DIR")
if [ -z "$WORKSPACE_REAL" ]; then
  block "не удалось нормализовать корень рабочего каталога — принадлежность файла не определить, блокирую."
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
    block "путь содержит «..» — не классифицируется, блокирую. Используй прямой путь без переходов вверх."
    ;;
esac

# Манифест — always-block, ДО исключения для путей шаблона: управляющая копия
# лежит внутри клона шаблона, и правка её через Edit/Write отключала бы гейт.
# Штатный путь изменения манифеста — bash generate-manifest.sh, не Edit.
case "$REAL_PATH" in
  */update-manifest.json)
    block "update-manifest.json правится только генератором (bash generate-manifest.sh), не напрямую — файл определяет, какие скиллы платформенные."
    ;;
esac

# Проверяем: это L1 файл? Точные workspace-relative префиксы не захватывают
# глобальный ~/.claude или соседний каталог с похожим именем (issue #528).
case "$REL_PATH" in
  .claude/skills/*|memory/protocol-*)

  # Исключение 1: FMT-exocortex-template — всегда разрешён
  if printf '%s' "$REAL_PATH" | grep -q 'FMT-exocortex-template'; then
    exit 0
  fi

  # Исключение 2: author_mode в params.yaml
  if [ -f "$WORKSPACE_DIR/params.yaml" ] && grep -qE '^author_mode:\s*true' "$WORKSPACE_DIR/params.yaml" 2>/dev/null; then
    exit 0
  fi

  # Исключение 3 (issue #311): свой навык — .claude/skills/<name>/ отсутствует
  # в манифесте платформы, update.sh его не затронет и не затрёт.
  # Требуем ИМЕННО поддиректорию (name/...) — плоский файл прямо в .claude/skills/
  # (напр. SKILL-INDEX.yaml) НЕ подпадает и блокируется ниже.
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
$WORKSPACE_DIR/FMT-exocortex-template"
    while IFS= read -r _mf_root; do
      [ -n "$_mf_root" ] || continue
      _mf_real=$(cd "$_mf_root" 2>/dev/null && pwd -P) || { MANIFEST_TRIED="$MANIFEST_TRIED $_mf_root (нет каталога);"; continue; }
      if [ -f "$_mf_real/update-manifest.json" ]; then
        MANIFEST="$_mf_real/update-manifest.json"
        break
      fi
      MANIFEST_TRIED="$MANIFEST_TRIED $_mf_real (нет манифеста);"
    done <<EOF_MF
$_mf_candidates
EOF_MF
    if [ -z "$MANIFEST" ]; then
      block "update-manifest.json не найден ни в одном известном месте шаблона:${MANIFEST_TRIED} — принадлежность скилла не доказать, блокирую. Задай IWE_TEMPLATE=<путь к клону FMT-exocortex-template> (или восстанови клон через update.sh) и повтори."
    fi
    if [ -n "$SKILL_NAME" ]; then
      # Разрешение только при ДОКАЗАННО прочитанном манифесте: сначала проверка,
      # что jq видит непустой .files (битый JSON / нет ключа / пустой список =
      # отказ инструмента, не «скилла нет»), и только потом поиск совпадения.
      if jq -e '.files | type=="array" and length>0' "$MANIFEST" >/dev/null 2>&1; then
        IN_MANIFEST=$(jq -r --arg prefix ".claude/skills/${SKILL_NAME}/" \
          '.files[]? | select(.path | startswith($prefix)) | .path' \
          "$MANIFEST" 2>/dev/null | head -1)
        if [ -z "$IN_MANIFEST" ]; then
          exit 0
        fi
      else
        block "манифест платформы не читается (битый JSON или пустой список файлов) — принадлежность скилла не доказать, блокирую. Восстанови update-manifest.json (git checkout или update.sh)."
      fi
    fi
  fi

  # Исключение 4 (issue #872): SKILL.md платформенного скилла, правка целиком
  # внутри блока USER-SPACE. Форма пути — ровно .claude/skills/<имя>/SKILL.md
  # (один уровень каталога); всё остальное сюда не попадает и блокируется ниже.
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
    # Разрешение только при явном ALLOW от проверки инварианта; пустой вывод,
    # падение python или любое иное значение = отказ.
    US_VERDICT=$(printf '%s' "$INPUT" | python3 -I -c "$USER_SPACE_PY" "$WORKSPACE_REAL" "$REAL_PATH" "$FILE_PATH" 2>/dev/null)
    if [ "$US_VERDICT" = "ALLOW" ]; then
      echo '{}'
      exit 0
    fi
    case "$US_VERDICT" in
      DENY:*) US_WHY="${US_VERDICT#DENY:}" ;;
      *) US_WHY="проверка блока USER-SPACE не выполнена (нет python3 или сбой)" ;;
    esac
    # The reason goes into a hand-built JSON string: drop quotes, backslashes and every control character.
    US_WHY=$(printf '%s' "$US_WHY" | tr '\n\r' '  ' | tr -d '"\134' | tr -d '[:cntrl:]')
    block "SKILL.md платформенного скилла принадлежит платформе (L1), update.sh перезаписывает его при обновлении. Свои дополнения вноси ТОЛЬКО между строками <!-- USER-SPACE --> и <!-- /USER-SPACE --> этого же файла: update.sh сохраняет этот блок. Всё остальное в файле, сами маркеры и текст до/после них не трогай. Причина отказа: ${US_WHY}. Каталог extensions/ помогает только скиллам, которые сами вызывают load-extensions.sh (например day-open, day-close); для остальных, включая fpf, он не читается. Если в этом SKILL.md нет маркеров, исключение не действует: маркеры в платформенный скилл добавляет сопровождающий шаблона (scripts/add-skill-markers.sh в клоне шаблона). Платформенное изменение → FMT-exocortex-template → update.sh."
  fi

  # Блокировать для обычных пользователей
  block "платформенные (L1) и пользовательские (L3) файлы — разные слои. Правило (CLAUDE.md §9): Авторская кастомизация → extensions/*.md. Платформенное изменение → FMT-exocortex-template → update.sh. Смешение слоёв = хрупкость при обновлении. Создай или обнови нужный файл в extensions/."
  ;;
esac

# Разрешить редактирование обычных файлов
echo '{}'
exit 0
