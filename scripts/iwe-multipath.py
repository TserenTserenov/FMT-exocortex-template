#!/usr/bin/env python3
"""
WP-295 Ф3: CLI iwe-multipath — run N parallel agent paths and pick the best.

Commands:
  iwe-multipath.py run     "<task>" [--n 3] [--selector heuristic|archgate] [--budget 5000]
  iwe-multipath.py score   "<text1>" "<text2>" ...  (score pre-collected responses)
  iwe-multipath.py reflect "<text>" --task "<task>" [--cycles 1] [--model ...]

see DP.SC.039 (multi-path / best-of-N), DP.ROLE.049 (Path Coordinator R32).
Verification class: open-loop only. Refuses on trivial/closed-loop.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import re
import sys

from iwe_agent_backend import invoke as invoke_agent


# ── constants ─────────────────────────────────────────────────────────────────

DEFAULT_N = 3
MAX_CONCURRENT = 3  # asyncio.Semaphore cap — avoids API throttle storms on N=5
DEFAULT_MODELS = ["high", "medium", "medium"]
BUDGET_TOKENS = 5000  # per-path hint passed in system note

OPEN_LOOP_CLASSES = {"open-loop", "problem-framing"}
ALLOWED_SELECTORS = {"heuristic", "archgate"}

# archgate (LLM-as-Judge) constants
DEFAULT_JUDGE_MODEL = "low"
ARCHGATE_SKIP_THRESHOLD = 0.30  # skip judge if heuristic gap > this

# reflect constants
REFLECT_MAX_CYCLES = 2

_FAIL_PREFIX = "[path-failed:"  # sentinel prefix for failed path results

_JUDGE_PROMPT = """\
You are a precise judge comparing two responses to the same task.

Task: {task}

Response A:
{resp_a}

---

Response B:
{resp_b}

---

Which response better answers the task? Consider completeness, accuracy, and relevance.
Reply with ONLY the letter "A" or "B" — nothing else."""

_REFLECT_PROMPT = """\
Review and improve this response to the given task.

Task: {task}

Response to improve:
{text}

---

Step 1: List 2-3 specific weaknesses (be concrete, not generic).
Step 2: Write an improved version that addresses those weaknesses.

Format your output exactly as:
CRITIQUE:
<your critique>

REVISED:
<improved response>"""


# ── scorer (deterministic, no LLM, no embeddings) ─────────────────────────────

def _heuristic_score(text: str, median_len: float) -> float:
    """Structural quality + anti-verbosity length-in-range. Weights sum to 1.0."""
    in_range = 1.0 if 0.5 * median_len <= len(text) <= 2.0 * median_len else 0.0
    headers = min(text.count("\n#"), 5) / 5
    list_items = min(text.count("\n-"), 10) / 10
    code_blocks = min(text.count("```"), 4) / 4
    return headers * 0.3 + list_items * 0.2 + code_blocks * 0.3 + in_range * 0.2


def score_all(responses: list[str]) -> list[float]:
    """Return heuristic score for each response (0.0 for failed paths)."""
    valid = [r for r in responses if not r.startswith(_FAIL_PREFIX)]
    if not valid:
        return [0.0] * len(responses)
    lengths = sorted(len(t) for t in valid)
    median_len = float(lengths[len(lengths) // 2])
    return [
        0.0 if r.startswith(_FAIL_PREFIX) else _heuristic_score(r, median_len)
        for r in responses
    ]


def pick_best_index(responses: list[str], scores: list[float]) -> int:
    """Return index of best non-failed response by score."""
    candidates = [
        (i, s) for i, (r, s) in enumerate(zip(responses, scores))
        if not responses[i].startswith(_FAIL_PREFIX)
    ]
    return max(candidates, key=lambda x: x[1])[0]


# ── archgate (LLM-as-Judge) ───────────────────────────────────────────────────

async def _judge_pairwise(task: str, resp_a: str, resp_b: str, model: str) -> str:
    """Compare two responses via LLM. Returns 'A' or 'B'."""
    prompt = _JUDGE_PROMPT.format(task=task, resp_a=resp_a, resp_b=resp_b)
    _, raw = await asyncio.to_thread(invoke_agent, prompt, model)
    m = re.search(r"\b([AB])\b", raw)
    if m:
        return m.group(1)
    print(f"[archgate] judge parse failure, raw={raw[:80]!r}, defaulting to A",
          file=sys.stderr)
    return "A"


async def _pick_archgate(task: str, responses: list[str], scores: list[float],
                         judge_model: str, n: int) -> int:
    """Select best index using archgate. Falls back to heuristic on score-gap."""
    valid = sorted(
        [(i, r, s) for i, (r, s) in enumerate(zip(responses, scores))
         if not r.startswith(_FAIL_PREFIX)],
        key=lambda x: x[2], reverse=True,
    )
    if not valid:
        return 0
    if len(valid) == 1:
        return valid[0][0]

    gap = valid[0][2] - valid[1][2]
    if gap > ARCHGATE_SKIP_THRESHOLD:
        print(f"[archgate] gap={gap:.3f} > {ARCHGATE_SKIP_THRESHOLD} — skipping judge",
              file=sys.stderr)
        return valid[0][0]

    # Choose candidates: top-2 for N≤3, top-3 for N>3 (tournament bracket)
    candidates = valid[:2] if n <= 3 else valid[:3]

    print(f"[archgate] judge call 1: path {candidates[0][0]+1} vs path {candidates[1][0]+1}",
          file=sys.stderr)
    winner = candidates[0] if await _judge_pairwise(
        task, candidates[0][1], candidates[1][1], judge_model) == "A" else candidates[1]

    if len(candidates) == 2:
        return winner[0]

    # Tournament: winner vs third candidate
    print(f"[archgate] judge call 2: winner vs path {candidates[2][0]+1}", file=sys.stderr)
    final = winner if await _judge_pairwise(
        task, winner[1], candidates[2][1], judge_model) == "A" else candidates[2]
    return final[0]


# ── reflexion ─────────────────────────────────────────────────────────────────

async def _reflect_once(task: str, text: str, model: str) -> tuple[str, str]:
    """One Reflexion cycle. Returns (critique, revised)."""
    prompt = _REFLECT_PROMPT.format(task=task, text=text)
    _, raw = await asyncio.to_thread(invoke_agent, prompt, model)

    if "REVISED:" not in raw:
        return "", raw  # parse failure — treat entire output as revised

    parts = raw.split("REVISED:", 1)
    revised = parts[1].strip()
    critique = parts[0].split("CRITIQUE:", 1)[1].strip() if "CRITIQUE:" in parts[0] else ""
    return critique, revised


async def _reflect_loop(task: str, text: str, cycles: int, model: str) -> str:
    current = text
    for cycle in range(1, cycles + 1):
        print(f"[reflect] cycle {cycle}/{cycles}", file=sys.stderr)
        critique, current = await _reflect_once(task, current, model)
        if critique:
            snippet = critique[:120] + ("..." if len(critique) > 120 else "")
            print(f"[reflect] critique: {snippet}", file=sys.stderr)
    return current


# ── runner ────────────────────────────────────────────────────────────────────

async def _run_one(task: str, model: str, path_index: int, budget: int,
                   sem: asyncio.Semaphore) -> str:
    """Run a single `claude -p` call and return its stdout. Returns sentinel on failure."""
    note = f"[Multi-path path {path_index + 1}, budget ~{budget} tokens] "
    prompt = note + task
    async with sem:
        ok, output = await asyncio.to_thread(invoke_agent, prompt, model)
    if not ok:
        err = output.strip()[:200]
        return f"{_FAIL_PREFIX} {err}]"
    return output.strip()


async def _run_all(task: str, n: int, models: list[str], budget: int) -> list[str]:
    """Start all N paths immediately; at most MAX_CONCURRENT active via semaphore."""
    sem = asyncio.Semaphore(MAX_CONCURRENT)
    coroutines = [_run_one(task, models[i % len(models)], i, budget, sem) for i in range(n)]
    return await asyncio.gather(*coroutines)


# ── commands ──────────────────────────────────────────────────────────────────

def cmd_run(args: argparse.Namespace) -> int:
    models = args.models.split(",") if args.models else DEFAULT_MODELS

    if args.verification_class and args.verification_class not in OPEN_LOOP_CLASSES:
        print(
            f"multi-path не применяется к verification_class={args.verification_class}. "
            "Для trivial/closed-loop используйте single-path.",
            file=sys.stderr,
        )
        return 1

    judge_model = args.judge_model or DEFAULT_JUDGE_MODEL
    print(f"[multi-path] N={args.n} paths, max_concurrent={MAX_CONCURRENT}, "
          f"selector={args.selector}", file=sys.stderr)
    if args.selector == "archgate":
        print(f"[archgate] judge_model={judge_model}, skip_threshold={ARCHGATE_SKIP_THRESHOLD}",
              file=sys.stderr)
    if parent_id := os.environ.get("MULTIPATH_PARENT_ID"):
        print(f"[multi-path] MULTIPATH_PARENT_ID={parent_id}", file=sys.stderr)

    responses = asyncio.run(_run_all(args.task, args.n, models, args.budget))

    failed_count = sum(1 for r in responses if r.startswith(_FAIL_PREFIX))
    if failed_count == args.n:
        print("ERROR: все пути завершились с ошибкой", file=sys.stderr)
        return 2

    scores = score_all(responses)

    if args.selector == "archgate":
        best_idx = asyncio.run(
            _pick_archgate(args.task, responses, scores, judge_model, args.n)
        )
    else:
        best_idx = pick_best_index(responses, scores)

    print(f"\n[multi-path] Результаты ({args.selector}):", file=sys.stderr)
    for i, (resp, score) in enumerate(zip(responses, scores)):
        marker = "→ BEST" if i == best_idx else "      "
        status = "FAIL" if resp.startswith(_FAIL_PREFIX) else f"score={score:.3f} len={len(resp)}"
        print(f"  {marker} Path {i+1}: {status}", file=sys.stderr)

    print(f"\n{'='*60}\nBEST (path {best_idx + 1}):\n{'='*60}", file=sys.stderr)
    print(responses[best_idx])
    return 0


def cmd_reflect(args: argparse.Namespace) -> int:
    text = sys.stdin.read().strip() if args.text == "-" else args.text
    if not text:
        print("ERROR: нет текста для улучшения", file=sys.stderr)
        return 1

    cycles = min(args.cycles, REFLECT_MAX_CYCLES)
    model = args.model or DEFAULT_MODELS[0]
    print(f"[reflect] cycles={cycles} model={model} task={args.task[:60]!r}", file=sys.stderr)

    result = asyncio.run(_reflect_loop(args.task, text, cycles, model))
    print(result)
    return 0


def cmd_score(args: argparse.Namespace) -> int:
    if not args.texts:
        print("ERROR: укажите хотя бы один текст", file=sys.stderr)
        return 1
    scores = score_all(args.texts)
    for i, (text, score) in enumerate(zip(args.texts, scores)):
        print(f"Path {i+1}: score={score:.3f} len={len(text)} preview={text[:80]!r}")
    return 0


# ── CLI ───────────────────────────────────────────────────────────────────────

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="iwe-multipath: Best-of-N parallel agent paths (DP.SC.039, Ф3 WP-295)"
    )
    sub = p.add_subparsers(dest="command", required=True)

    run_p = sub.add_parser("run", help="Запустить N путей параллельно и выбрать лучший")
    run_p.add_argument("task", help="Задача для всех путей")
    run_p.add_argument("--n", type=int, default=DEFAULT_N)
    run_p.add_argument("--selector", default="heuristic",
                       choices=sorted(ALLOWED_SELECTORS))
    run_p.add_argument("--judge-model", default="", dest="judge_model",
                       help=f"Модель судьи для archgate (default: {DEFAULT_JUDGE_MODEL})")
    run_p.add_argument("--budget", type=int, default=BUDGET_TOKENS)
    run_p.add_argument("--models", default="")
    run_p.add_argument("--verification-class", default="", dest="verification_class")

    score_p = sub.add_parser("score", help="Оценить готовые тексты эвристикой")
    score_p.add_argument("texts", nargs="+")

    ref_p = sub.add_parser("reflect", help="Улучшить текст через Reflexion-loop")
    ref_p.add_argument("text", help='Текст для улучшения (или "-" для stdin)')
    ref_p.add_argument("--task", required=True, help="Исходная задача (контекст)")
    ref_p.add_argument("--cycles", type=int, default=1,
                       help=f"Кол-во итераций (default=1, max={REFLECT_MAX_CYCLES})")
    ref_p.add_argument("--model", default="", help="Модель для reflexion")

    return p


def main() -> int:
    parser = _build_parser()
    args = parser.parse_args()
    if args.command == "run":
        return cmd_run(args)
    if args.command == "score":
        return cmd_score(args)
    if args.command == "reflect":
        return cmd_reflect(args)
    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
