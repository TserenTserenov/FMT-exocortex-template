r"""Регресс-тест по времени (охрана destructive-guard, issue #1148): склейка `\`-переносов линейна.

Команда с ~2000 переносов строк должна разбираться быстрее 1 с.
До фикса perl-редукция heredoc работала квадратично (continued_header заново
проходила всю накопленную строку каждую итерацию): 2000 переносов ≈ 10 с на
двухъядерной машине, ~1.2 с на быстрой. Запас до порога на медленном CI —
не менее четырёхкратный (замер после фикса ≈ 0.12 с).

Запуск: python3 perf_cases.py [<хук>]  (по умолчанию — хук рядом, .claude/hooks/destructive-guard.sh)
"""
import json
import pathlib
import subprocess
import sys
import tempfile
import time

CONTINUATIONS = 2000
TIME_LIMIT_S = 1.0

# Хук читает репозиторий в своём cwd — запускаем из каталога вне репозитория,
# как в long_cases.py.
NEUTRAL_CWD = tempfile.mkdtemp(prefix="dg-perf-")


def main():
    hook = sys.argv[1] if len(sys.argv) > 1 else str(
        pathlib.Path(__file__).resolve().parents[2] / "destructive-guard.sh")
    command = "git status" + " \\\n" + " \\\n".join(f"b{i}" for i in range(CONTINUATIONS))
    payload = json.dumps({"tool_input": {"command": command}})
    started = time.monotonic()
    proc = subprocess.run(["bash", hook], input=payload, capture_output=True, text=True,
                          encoding="utf-8", errors="replace", cwd=NEUTRAL_CWD)
    elapsed = time.monotonic() - started
    ok = proc.returncode == 0 and elapsed < TIME_LIMIT_S
    print(f"{'ok ' if ok else 'НЕ '} {CONTINUATIONS} переносов ({len(command) // 1024} КБ): "
          f"{elapsed:.2f} с (порог {TIME_LIMIT_S:.1f} с), код {proc.returncode}")
    print(f"итог: {1 if ok else 0} из 1 как ожидалось")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
