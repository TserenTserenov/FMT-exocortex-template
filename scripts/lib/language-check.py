#!/usr/bin/env python3
"""Alert-only проверка: финальный ответ пилоту вышел не на русском.

WP-484 Ф89 (11.08) — дважды за одну сессию финальный ответ вышел на
английском после плотного англоязычного технического участка (git log/diff,
commit-хэши, промпты внешним агентам). Второй раз — сразу после того, как
первый эпизод был зафиксирован в память той же сессии: текстовое правило без
механической проверки не сработало дважды подряд.

Модель (peer-session 2026-08-12-06-wp484-watchdog-lang-check, ходы 11-12):
вырезать fenced/inline код, URL, файловые пути перед подсчётом — они всегда
латиница и не относятся к вопросу «на каком языке написан ОТВЕТ». Скобки
вырезаются не целиком: A2 (inject-communication-style.sh) требует английские
термины ПОСЛЕ русского описания в скобках — «переход на новую версию марафона
(РП330)» — но кириллические asides в скобках («см. выше», «например, на
тесте всё ок») тоже частый паттерн, и их вырезание убирало бы кириллический
сигнал, а не английский термин. Классификатор оценивает КАЖДЫЙ top-level
скобочный блок целиком (>50% латиницы внутри всего блока, включая любую
вложенность, → это глосса, вырезать; иначе — обычный текст, оставить) — не
рекурсивный спуск по уровням вложенности. Known limitation (peer-session
ход 17, сознательно принято как advisory-инструмент, не автокорректор):
вложенный смешанный случай "(важное значение (important meaning) объяснение)"
может дать неверную классификацию всего блока, если внешний и внутренний
уровень имеют разный язык — вложенность на практике редка, а ложный alert
стоит лишнего просмотра, не потери данных.

Использование:
    echo "$текст" | python3 language-check.py
    → JSON {"alert": bool, "ratio": float, "reason": str} в stdout

Alert-only: вызывающий код решает, что делать с сигналом (лог,
additionalContext, .err) — этот модуль никогда не блокирует и не изменяет
входной текст.
"""
import json
import re
import sys

# non-blocking self-check шаг (решение Ф89: alert, не block) — порог и лимиты
# рабочие гипотезы, требуют калибровки на живых ответах.
CYRILLIC_RATIO_THRESHOLD = 0.30
MIN_RESIDUAL_LEN = 20
GLOSS_LATIN_THRESHOLD = 0.50

_CYRILLIC_RE = re.compile(r"[Ѐ-ӿ]")
_LATIN_RE = re.compile(r"[A-Za-z]")
_ALPHA_RE = re.compile(r"[Ѐ-ӿA-Za-z]")

_FENCED_CODE_RE = re.compile(r"```.*?```", re.DOTALL)
_INLINE_CODE_RE = re.compile(r"`[^`]*`")
_URL_RE = re.compile(r"https?://\S+")
# Путь: содержит `/` ИЛИ известное файловое расширение, без пробелов внутри.
# `\w` в Python re юникодный по умолчанию — матчит кириллицу наравне с
# латиницей, из-за чего обычные русские конструкции через слэш («и/или»,
# «да/нет», «чтение/запись») распознавались как путь и вырезались вместе с
# кириллицей внутри них (review-02, peer-session ход 18). Явный ASCII-класс
# вместо `\w` — пути и расширения файлов физически не бывают кириллическими.
_PATH_RE = re.compile(
    r"\b(?:[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]+\b|\b[A-Za-z0-9_-]+\.(?:sh|py|md|yaml|yml|json|ts|tsx|js|txt|log)\b"
)


def _strip_glosses(text):
    """Вырезать топ-уровневые скобки, чьё содержимое >50% латиницы.

    Ручной посимвольный проход вместо regex — `[^)]*` не держит вложенные
    скобки (peer-session ход 12), а вложенность в русской прозе реальна:
    "(термин (уточнение) ещё текст)".
    """
    out = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "(":
            depth = 1
            j = i + 1
            while j < n and depth > 0:
                if text[j] == "(":
                    depth += 1
                elif text[j] == ")":
                    depth -= 1
                j += 1
            inner = text[i + 1 : j - 1] if depth == 0 else text[i + 1 : n]
            alpha_len = len(_ALPHA_RE.findall(inner))
            latin_len = len(_LATIN_RE.findall(inner))
            is_gloss = alpha_len > 0 and (latin_len / alpha_len) > GLOSS_LATIN_THRESHOLD
            if not is_gloss:
                out.append(text[i:j] if depth == 0 else text[i:n])
            i = j if depth == 0 else n
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def strip_non_prose(text):
    """Вырезать код/URL/пути/A2-глоссы перед подсчётом языка ответа."""
    text = _FENCED_CODE_RE.sub(" ", text)
    text = _INLINE_CODE_RE.sub(" ", text)
    text = _URL_RE.sub(" ", text)
    text = _PATH_RE.sub(" ", text)
    text = _strip_glosses(text)
    return text


def check_language(text):
    residual = strip_non_prose(text)
    alpha_chars = _ALPHA_RE.findall(residual)

    # MIN_RESIDUAL_LEN гейтит статистическую значимость ratio, которая зависит
    # от количества БУКВ, не общей длины остатка (review-02, peer-session ход
    # 18): текст с обилием WP-номеров/дат/хэшей давал длинный residual с 1-2
    # буквами внутри — ratio считался по микровыборке (0/1, 1/2…), давая
    # alert почти из ничего. Мерить len(alpha_chars) напрямую.
    if len(alpha_chars) < MIN_RESIDUAL_LEN:
        return {"alert": False, "ratio": None, "reason": "too few alphabetic chars after stripping code/paths/glosses, skipped"}

    cyrillic_count = len(_CYRILLIC_RE.findall(residual))
    ratio = cyrillic_count / len(alpha_chars)

    if ratio < CYRILLIC_RATIO_THRESHOLD:
        return {"alert": True, "ratio": round(ratio, 3), "reason": f"cyrillic ratio {ratio:.2f} below threshold {CYRILLIC_RATIO_THRESHOLD}"}

    return {"alert": False, "ratio": round(ratio, 3), "reason": "cyrillic ratio within threshold"}


def main():
    text = sys.stdin.read()
    result = check_language(text)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
