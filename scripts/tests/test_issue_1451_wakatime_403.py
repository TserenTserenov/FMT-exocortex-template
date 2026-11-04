"""
Issue #1451: WakaTime answers HTTP 403 on summaries for a plugin API key.

wakatime-day-total.py must:
  1. 403 + today + status_bar date matches -> seconds, exit 0.
  2. 403 + today + status_bar date mismatch -> exit 3, no substitution.
  3. 403 + past day, no OAuth -> status_bar not called, exit 3, reason names
     WAKATIME_OAUTH_TOKEN.
  4. WAKATIME_OAUTH_TOKEN set -> summaries with Bearer, token never printed.
  5. 200 summaries -> old result, status_bar not called.
No network: urllib.request.urlopen is replaced by a fake.
"""

import importlib.util
import io
import json
import urllib.error
from datetime import date, timedelta
from pathlib import Path

import pytest

SCRIPT = Path(__file__).parent.parent / "wakatime-day-total.py"
# Obviously fake values; never real credentials.
PLUGIN_KEY = "fake-plugin-key"
OAUTH_TOKEN = "fake-oauth-value"


def load_module():
    spec = importlib.util.spec_from_file_location("wakatime_day_total", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


class FakeWakaTime:
    """Records requests; answers by endpoint."""

    def __init__(self, summaries=None, summaries_status=200, status_bar=None):
        self.summaries = summaries
        self.summaries_status = summaries_status
        self.status_bar = status_bar
        self.requests = []

    def __call__(self, req, timeout=None):
        self.requests.append(req)
        url = req.full_url
        if "/summaries?" in url:
            if self.summaries_status != 200:
                raise urllib.error.HTTPError(
                    url, self.summaries_status, "FORBIDDEN", {}, io.BytesIO(b"")
                )
            return FakeResponse(json.dumps(self.summaries).encode())
        if url.endswith("/status_bar/today"):
            return FakeResponse(json.dumps(self.status_bar).encode())
        raise AssertionError(f"unexpected URL {url}")

    def urls(self):
        return [r.full_url for r in self.requests]


def run(monkeypatch, capsys, fake, target, oauth=None):
    module = load_module()
    monkeypatch.setattr(module.urllib.request, "urlopen", fake)
    monkeypatch.setenv("WAKATIME_API_KEY", PLUGIN_KEY)
    if oauth is None:
        monkeypatch.delenv("WAKATIME_OAUTH_TOKEN", raising=False)
    else:
        monkeypatch.setenv("WAKATIME_OAUTH_TOKEN", oauth)
    monkeypatch.setattr(module.sys, "argv", ["wakatime-day-total.py", target])
    code = 0
    try:
        module.main()
    except SystemExit as exc:
        code = exc.code
    out = capsys.readouterr()
    return code, out.out.strip(), out.out + out.err


def status_bar_body(day, seconds):
    return {"data": {"range": {"date": day}, "grand_total": {"total_seconds": seconds}}}


def summaries_body(day, seconds):
    return {"data": [{"range": {"date": day}, "grand_total": {"total_seconds": seconds}}]}


def test_403_today_uses_status_bar_when_date_matches(monkeypatch, capsys):
    today = date.today().isoformat()
    fake = FakeWakaTime(summaries_status=403, status_bar=status_bar_body(today, 9899.6))
    code, out, _ = run(monkeypatch, capsys, fake, today)
    assert code == 0
    assert out == "9900"
    assert fake.urls()[-1].endswith("/status_bar/today")
    assert fake.requests[-1].get_header("Authorization").startswith("Basic ")


def test_403_today_date_mismatch_gives_no_value(monkeypatch, capsys):
    today = date.today()
    other = (today - timedelta(days=1)).isoformat()
    fake = FakeWakaTime(summaries_status=403, status_bar=status_bar_body(other, 3600))
    code, out, _ = run(monkeypatch, capsys, fake, today.isoformat())
    assert code == 3
    assert out.startswith("(") and other in out
    assert "3600" not in out


def test_403_past_day_without_oauth_skips_status_bar(monkeypatch, capsys):
    past = (date.today() - timedelta(days=2)).isoformat()
    fake = FakeWakaTime(summaries_status=403, status_bar=status_bar_body(past, 3600))
    code, out, _ = run(monkeypatch, capsys, fake, past)
    assert code == 3
    assert "WAKATIME_OAUTH_TOKEN" in out
    assert not any("status_bar" in u for u in fake.urls())


@pytest.mark.parametrize("status", [200, 403])
def test_oauth_token_sent_as_bearer_and_never_printed(monkeypatch, capsys, status):
    past = (date.today() - timedelta(days=3)).isoformat()
    fake = FakeWakaTime(summaries=summaries_body(past, 1200), summaries_status=status)
    code, out, everything = run(monkeypatch, capsys, fake, past, oauth=OAUTH_TOKEN)
    assert fake.requests[0].get_header("Authorization") == f"Bearer {OAUTH_TOKEN}"
    assert all(PLUGIN_KEY not in r.get_header("Authorization") for r in fake.requests)
    assert not any("status_bar" in u for u in fake.urls())
    assert OAUTH_TOKEN not in everything
    if status == 200:
        assert (code, out) == (0, "1200")
    else:
        assert code == 3 and "403" in out


def test_summaries_200_keeps_old_path(monkeypatch, capsys):
    today = date.today().isoformat()
    fake = FakeWakaTime(summaries=summaries_body(today, 4321.9), status_bar=None)
    code, out, _ = run(monkeypatch, capsys, fake, today)
    assert (code, out) == (0, "4321")
    assert len(fake.requests) == 1 and "/summaries?" in fake.urls()[0]
    assert fake.requests[0].get_header("Authorization").startswith("Basic ")
