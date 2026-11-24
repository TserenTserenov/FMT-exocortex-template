#!/usr/bin/env python3
"""Tests for scripts/postman.py (WP-418 F10). Run: python3 scripts/tests/test-postman.py"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "scripts" / "postman.py"
failures = []


def expect(name, cond, detail=""):
    if not cond:
        failures.append(f"{name}: {detail}")


with tempfile.TemporaryDirectory() as ws:
    gov = Path(ws) / "GOV"
    (gov / "inbox" / "WP-7").mkdir(parents=True)
    (gov / "inbox" / "WP-7" / "WP-7.md").write_text("---\nwp: 7\n---\n", encoding="utf-8")
    empty_params = Path(ws) / "params.yaml"
    empty_params.write_text("", encoding="utf-8")
    env = {**os.environ, "IWE_WORKSPACE": ws, "IWE_GOVERNANCE_REPO": "GOV"}

    def deliver(to, *extra, summary="выжимка"):
        r = subprocess.run([sys.executable, str(TOOL), "deliver", "--to", to, "--from", "РП-418",
                            "--pointer", "p.md", "--summary", summary, "--params", str(empty_params), *extra],
                           capture_output=True, text=True, env=env)
        return r.returncode, json.loads(r.stdout or "{}"), r.stderr

    box = gov / "inbox" / "WP-7" / "INBOX.md"

    # 1. Delivered once; a retry of the same parcel is the same delivery, no second entry.
    rc, out, err = deliver("WP-7")
    expect("first delivery", rc == 0 and out.get("outcome") == "доставлено" and out.get("entry") == "И-1"
           and out.get("duplicate") is False, f"{rc} {out} {err}")
    first_id = out.get("delivery_id", "")
    expect("derived delivery id", first_id.startswith("d-") and len(first_id) == 18, first_id)
    rc, out, err = deliver("WP-7")
    expect("retry is idempotent", rc == 0 and out.get("outcome") == "доставлено" and out.get("duplicate") is True
           and out.get("delivery_id") == first_id, f"{rc} {out} {err}")
    expect("one entry in the box", box.read_text(encoding="utf-8").count("\n## И-") == 1, box.read_text(encoding="utf-8"))

    # 2. Another parcel and an explicit id: a new entry carrying that id.
    rc, out, err = deliver("WP-7", "--delivery-id", "manual-1", summary="другая")
    expect("explicit id delivered", rc == 0 and out.get("entry") == "И-2" and out.get("delivery_id") == "manual-1", f"{out} {err}")
    expect("entry carries the id", "Доставка: manual-1" in box.read_text(encoding="utf-8"))

    # 3. Closed WP: rejected with the deferred-list address, nothing written.
    rc, out, err = deliver("WP-99")
    expect("closed WP rejected", rc == 1 and out.get("outcome") == "отвергнуто"
           and out.get("address", "").endswith("inbox/backlog-with-triggers.md"), f"{out} {err}")
    expect("closed WP: no folder created", not (gov / "inbox" / "WP-99").exists())

    # 4. Kinds whose executor is not on the contract yet, and an unknown name.
    for name in ("agent", "owner", "someone"):
        rc, out, err = deliver(name)
        expect(f"{name} not supported", rc == 1 and out.get("outcome") == "не поддерживается", f"{out} {err}")

    # 5. A bad explicit id is rejected by the executor, not written.
    before = box.read_text(encoding="utf-8")
    rc, out, err = deliver("WP-7", "--delivery-id", "bad id;x", summary="третья")
    expect("bad id rejected", rc == 1 and out.get("outcome") == "отвергнуто", f"{out} {err}")
    expect("bad id: box unchanged", box.read_text(encoding="utf-8") == before)

    # 6. Busy mailbox (lock held by a live process): temporary failure, exit 3.
    #    The lock lives in the checkout (here no git: next to the mailbox), not in TMPDIR.
    lock = gov / "inbox" / "WP-7" / ".INBOX.lock"
    lock.mkdir()
    (lock / "pid").write_text(str(os.getpid()), encoding="utf-8")
    rc, out, err = deliver("WP-7", summary="четвёртая")
    expect("busy box is a temporary failure", rc == 3 and out.get("outcome") == "временный сбой", f"{rc} {out} {err}")

    # 7. A lock left by a dead process is removed and the delivery goes through.
    dead = subprocess.Popen(["true"])
    dead.wait()
    (lock / "pid").write_text(str(dead.pid), encoding="utf-8")
    rc, out, err = deliver("WP-7", summary="четвёртая")
    expect("stale lock removed", rc == 0 and out.get("outcome") == "доставлено" and not lock.exists(), f"{rc} {out} {err}")

    # 8. A book row with a placeholder the name pattern does not provide: JSON outcome, exit 2.
    bad_book = Path(ws) / "bad-book.yaml"
    bad_book.write_text((ROOT / "scripts" / "postman-address-book.yaml").read_text(encoding="utf-8")
                        .replace("inbox/WP-{n}/INBOX.md", "inbox/WP-{y}/INBOX.md"), encoding="utf-8")
    rc, out, err = deliver("WP-7", "--book", str(bad_book), summary="пятая")
    expect("bad placeholder: invalid book", rc == 2 and out.get("outcome") == "неизвестно" and "{y}" not in err, f"{rc} {out} {err}")
    broken = Path(ws) / "broken.yaml"
    broken.write_text("addressees: [", encoding="utf-8")
    rc, out, err = deliver("WP-7", "--book", str(broken), summary="пятая")
    expect("broken YAML: JSON outcome, exit 2", rc == 2 and out.get("outcome") == "неизвестно", f"{rc} {out} {err}")

if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
print("postman: все проверки прошли (8 групп)")
