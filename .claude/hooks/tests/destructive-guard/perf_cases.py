r"""Регресс-тест по времени (охрана destructive-guard, issue #1148): склейка `\`-переносов линейна.

До фикса perl-редукция heredoc работала квадратично (continued_header заново
проходила всю накопленную строку каждую итерацию): 2000 переносов ≈ 10 с на
двухъядерной машине, ~1.2 с на быстрой.

Тест не зависит от скорости машины. Он мерит добавку времени к короткой команде
на той же машине (сам запуск хука — свой разбор и три выпущенные проверки — на
медленном CI занимает около секунды, поэтому абсолютный порог 1 с срабатывал без
всякой квадратичности): добавка на 2000 переносов должна быть меньше 3 с
(квадратичный разбор на CI давал ≈ 10 с). Рост добавки при вчетверо большем числе
переносов печатается для сведения (линейный разбор даёт ≈ 4, квадратичный ≈ 16):
под нагрузкой он шумит, поэтому в условие теста не входит.

Запуск: python3 perf_cases.py [<хук>]  (по умолчанию — хук рядом, .claude/hooks/destructive-guard.sh)
"""
import json
import pathlib
import subprocess
import sys
import tempfile
import time

CONTINUATIONS = 2000
GROWTH_FACTOR = 4
EXTRA_LIMIT_S = 3.0
# Below this the extra time is timer noise and the growth ratio means nothing.
NOISE_FLOOR_S = 0.05

# The hook reads the repository in its cwd — run from a directory outside the repository,
# as in long_cases.py.
NEUTRAL_CWD = tempfile.mkdtemp(prefix="dg-perf-")


def hook_seconds(hook, continuations):
    """Best of two hook calls on `git status` followed by that many continued lines."""
    command = "git status" + "".join(f" \\\nb{i}" for i in range(continuations))
    payload = json.dumps({"tool_input": {"command": command}})
    best = None
    for _ in range(2):
        started = time.monotonic()
        proc = subprocess.run(["bash", hook], input=payload, capture_output=True, text=True,
                              encoding="utf-8", errors="replace", cwd=NEUTRAL_CWD)
        elapsed = time.monotonic() - started
        if proc.returncode != 0:
            raise SystemExit(f"НЕ  {continuations} переносов: код {proc.returncode}, ожидался 0")
        best = elapsed if best is None else min(best, elapsed)
    return best


def main():
    hook = sys.argv[1] if len(sys.argv) > 1 else str(
        pathlib.Path(__file__).resolve().parents[2] / "destructive-guard.sh")
    baseline = hook_seconds(hook, 0)
    extra = hook_seconds(hook, CONTINUATIONS) - baseline
    extra_grown = hook_seconds(hook, CONTINUATIONS * GROWTH_FACTOR) - baseline
    growth = extra_grown / max(extra, NOISE_FLOOR_S)
    ok = extra < EXTRA_LIMIT_S
    print(f"{'ok ' if ok else 'НЕ '} короткая команда {baseline:.2f} с; "
          f"{CONTINUATIONS} переносов: +{extra:.2f} с (порог {EXTRA_LIMIT_S:.1f} с); "
          f"{CONTINUATIONS * GROWTH_FACTOR} переносов: +{extra_grown:.2f} с, "
          f"рост в {growth:.1f} раза (для сведения)")
    print(f"итог: {1 if ok else 0} из 1 как ожидалось")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
