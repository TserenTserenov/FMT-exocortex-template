#!/usr/bin/env python3
"""Postman: deliver a ready parcel to an addressee by the address book (WP-418 F10).

Delivery contract (DP.SC.134, role DP.ROLE.044 section 4): the sender passes a
delivery id, an immutable parcel and the addressee's name; it always gets one
outcome back from a closed list:
  доставлено | отвергнуто | не поддерживается | временный сбой | неизвестно

Usage:
  postman.py deliver --to NAME --from FROM --pointer POINTER --summary SUMMARY
                     [--delivery-id ID]

Without --delivery-id the id is derived from the parcel (addressee, sender,
pointer, summary), so a retry of the same parcel is the same delivery.

stdout: one JSON object {delivery_id, to, kind, outcome, reason, address,
entry, duplicate}. Exit 0 when delivered (including an earlier delivery of the
same id), 3 on a temporary failure (safe to retry with the same id), 1 otherwise;
exit 2 when the call or the address book is invalid (JSON with «неизвестно» and the reason;
argparse usage errors print to stderr only). An unexpected error still prints a JSON
outcome «неизвестно» with exit 1.

Executors connected to the contract are listed in ADAPTERS; an addressee kind
whose executor is not there gets «не поддерживается».
"""
import argparse
import hashlib
import importlib.util
import json
import re
import shlex
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DELIVERED, REJECTED, UNSUPPORTED, TEMPORARY, UNKNOWN = (
    "доставлено", "отвергнуто", "не поддерживается", "временный сбой", "неизвестно")
EXIT_CODES = {DELIVERED: 0, TEMPORARY: 3}
EXECUTOR_TIMEOUT_S = 30


def load_book_module():
    spec = importlib.util.spec_from_file_location("postman_address_book", ROOT / "scripts" / "postman-address-book.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def derive_delivery_id(to: str, sender: str, pointer: str, summary: str) -> str:
    digest = hashlib.sha256("\x1f".join((to, sender, pointer, summary)).encode("utf-8")).hexdigest()
    return "d-" + digest[:16]


def deliver_wp_inbox(command: list[str], parcel: dict) -> dict:
    """Adapter for scripts/wp-inbox.sh add: dedup by delivery id is atomic with the write."""
    cmd = command + ["--from", parcel["from"], "--pointer", parcel["pointer"],
                     "--summary", parcel["summary"], "--delivery-id", parcel["delivery_id"]]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        out, err = proc.communicate(timeout=EXECUTOR_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        # SIGTERM first: the executor's EXIT trap releases the mailbox lock.
        proc.terminate()
        try:
            proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
        return {"outcome": UNKNOWN, "reason": f"программа ящиков не ответила за {EXECUTOR_TIMEOUT_S} с; повтор с тем же идентификатором безопасен"}
    out, err = out.strip(), err.strip()
    if proc.returncode == 0:
        m = re.match(r"^И-(\d+) (уже )?записана", out)
        if not m:
            return {"outcome": UNKNOWN, "reason": f"непонятный ответ программы ящиков: {out!r}"}
        return {"outcome": DELIVERED, "reason": "", "entry": f"И-{m.group(1)}", "duplicate": bool(m.group(2))}
    # wp-inbox.sh shares exit 1 between «busy» and «no card»; its messages tell them apart.
    if proc.returncode == 1 and "занят" in err:
        return {"outcome": TEMPORARY, "reason": err}
    if proc.returncode == 1 and "нет карточки" in err:
        return {"outcome": REJECTED, "reason": "адресат закрылся до доставки: " + err}
    if proc.returncode == 2:
        return {"outcome": REJECTED, "reason": err}
    return {"outcome": UNKNOWN, "reason": f"код {proc.returncode}: {err}"}


ADAPTERS = {"scripts/wp-inbox.sh": deliver_wp_inbox}


def deliver(book, rows: list[dict], parcel: dict) -> dict:
    base = {"delivery_id": parcel["delivery_id"], "to": parcel["to"], "kind": None,
            "address": None, "entry": None, "duplicate": False}
    found = book.resolve(rows, parcel["to"])
    if found is None:
        return {**base, "outcome": UNSUPPORTED, "reason": "адресата нет в адресной книге"}
    base.update(kind=found["kind"], address=found["address"])
    if found["closed"]:
        return {**base, "outcome": REJECTED,
                "reason": "адресат закрыт: строку записать в список отложенного по протоколу работы"}
    executor = found["executor"]
    if not executor.startswith("script:"):
        return {**base, "outcome": UNSUPPORTED, "reason": "исполнитель этого вида ещё не подключён к договору доставки"}
    command = shlex.split(executor[len("script:"):])
    adapter = ADAPTERS.get(command[0])
    if adapter is None:
        return {**base, "outcome": UNSUPPORTED, "reason": f"исполнитель {command[0]} не подключён к договору доставки"}
    command[0] = str(ROOT / command[0])
    return {**base, **adapter(["bash"] + command, parcel)}


def report(result: dict, code: int) -> int:
    print(json.dumps(result, ensure_ascii=False))
    return code


def run(a) -> int:
    try:
        book = load_book_module()
        rows, file_problems = book.load_rows(a.book or book.DEFAULT_BOOK, a.params or book.DEFAULT_PARAMS)
    except (SystemExit, ImportError) as exc:
        return report({"delivery_id": a.delivery_id, "to": a.to, "outcome": UNKNOWN,
                       "reason": f"адресная книга не прочитана: {exc}"}, 2)
    problems = book.check(rows, file_problems)
    if problems:
        return report({"delivery_id": a.delivery_id, "to": a.to, "outcome": UNKNOWN,
                       "reason": "адресная книга неверна: " + "; ".join(problems)}, 2)
    parcel = {"to": a.to, "from": a.sender, "pointer": a.pointer, "summary": a.summary,
              "delivery_id": a.delivery_id or derive_delivery_id(a.to, a.sender, a.pointer, a.summary)}
    result = deliver(book, rows, parcel)
    return report(result, EXIT_CODES.get(result["outcome"], 1))


def main() -> int:
    ap = argparse.ArgumentParser(description="Почтальон: доставить готовое отправление адресату по адресной книге.")
    ap.add_argument("command", choices=["deliver"])
    ap.add_argument("--to", required=True)
    ap.add_argument("--from", dest="sender", required=True)
    ap.add_argument("--pointer", required=True)
    ap.add_argument("--summary", required=True)
    ap.add_argument("--delivery-id")
    ap.add_argument("--book", type=Path)
    ap.add_argument("--params", type=Path)
    a = ap.parse_args()
    try:
        return run(a)
    except Exception as exc:  # the contract promises an outcome even on a bug here
        print(f"postman: непредвиденная ошибка: {exc!r}", file=sys.stderr)
        return report({"delivery_id": a.delivery_id, "to": a.to, "outcome": UNKNOWN,
                       "reason": f"непредвиденная ошибка Почтальона: {type(exc).__name__}"}, 1)


if __name__ == "__main__":
    sys.exit(main())
