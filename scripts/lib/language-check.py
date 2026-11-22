#!/usr/bin/env python3
"""Alert-only check: the final response to the pilot was not in Russian.

WP-484 Phase89 (11.08) — twice within one session the final response was produced in
English after a dense English-language technical segment (git log/diff,
commit-hashes, prompts to external agents). The second time — immediately after, when
the first episode had been recorded into the memory of that same session: a text-only rule without
a mechanical check failed twice in a row.

Model (peer-session 2026-08-12-06-wp484-watchdog-lang-check, turns 11-12):
strip out fenced/inline code, URL, file paths before counting — they are always
Latin script and are unrelated to the question «in what language is the RESPONSE written». Parenthetical blocks
are not stripped out entirely: A2 (inject-communication-style.sh) requires English
terms AFTER the Russian description inside parentheses — «transition to the new marathon version
(WP330)» — but Cyrillic asides inside parentheses («see. above», «for example, on
the test is fine») also a frequent pattern, and stripping them out would remove the Cyrillic
signal, not an English term. The classifier evaluates EVERY top-level
parenthetical block as a whole (more than 50 percent Latin script inside the entire block, including any (>50% Latin script inside the entire block, including any
nesting, → this is a gloss, strip it; otherwise — plain text, keep it) — not
recursive descent through nesting levels. Known limitation (peer-session
move 17, deliberately accepted as an advisory-tool, not an auto-corrector):
nested mixed-script case "(important meaning (important meaning) explanation)"
may produce an incorrect classification of the entire block, if the outer and inner
levels have different languages -- nesting is rare in practice and a false alert — nesting is rare in practice, and a false alert
is worth an extra review, not data loss.

Usage:
    echo "$text" | python3 language-check.py
    → JSON {"alert": bool, "ratio": float, "reason": str} to stdout

Alert-only: the calling code decides, what to do with the signal (log,
additionalContext, .err) — this module never blocks or modifies
the input text.
"""
import json
import re
import sys

# non-blocking self-check step (Phase decision89: alert, not block) — threshold and limits
# Working hypotheses that need calibration on real responses.
CYRILLIC_RATIO_THRESHOLD = 0.30
MIN_RESIDUAL_LEN = 20
GLOSS_LATIN_THRESHOLD = 0.50

_CYRILLIC_RE = re.compile(r"[\u0400-\u052f]")
_LATIN_RE = re.compile(r"[A-Za-z]")
_ALPHA_RE = re.compile(r"[\u0400-\u052fA-Za-z]")

_FENCED_CODE_RE = re.compile(r"```.*?```", re.DOTALL)
_INLINE_CODE_RE = re.compile(r"`[^`]*`")
_URL_RE = re.compile(r"https?://\S+")
# A path contains / or a known file extension, with no internal spaces.
# `\w` in Python re Unicode by default — matches Cyrillic the same as
# Latin characters, of-which is why ordinary Russian constructions using a slash («and/or»,
# «yes/no», «read/write») were recognized as a path and stripped together with
# the Cyrillic characters inside them (review-02, peer-session turn 18). Explicit ASCII-class
# instead of `\w` — file paths and extensions are physically never Cyrillic.
_PATH_RE = re.compile(
    r"\b(?:[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]+\b|\b[A-Za-z0-9_-]+\.(?:sh|py|md|yaml|yml|json|ts|tsx|js|txt|log)\b"
)


def _strip_glosses(text):
    """Strip top-level parentheses, whose content is >50% Latin characters.

    Manual character-by-character pass instead of regex — `[^)]*` does not handle nested
    parentheses (peer-session turn 12), and nesting in Russian prose is real:
    "(term (clarification) more text)".
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
    """Strip code/URL/paths/A2-glosses before counting the language of the response."""
    text = _FENCED_CODE_RE.sub(" ", text)
    text = _INLINE_CODE_RE.sub(" ", text)
    text = _URL_RE.sub(" ", text)
    text = _PATH_RE.sub(" ", text)
    text = _strip_glosses(text)
    return text


def check_language(text):
    residual = strip_non_prose(text)
    alpha_chars = _ALPHA_RE.findall(residual)

    # MIN_RESIDUAL_LEN gates the statistical significance of ratio, which depends on
    # the number of LETTERS, not the total length of the residual (review-02, peer-session turn
    # 18): text with an abundance of WP-numbers/dates/hashes produced a long residual with 1-2
    # letters inside it — ratio was computed on a micro-sample (0/1, 1/2…), yielding
    # alert from almost nothing. Measure len(alpha_chars) directly.
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
