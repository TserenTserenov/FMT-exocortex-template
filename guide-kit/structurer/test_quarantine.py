"""
test_quarantine.py — guide-kit structurer tests, quarantine slice (FORMAT.md §4a).
Run: cd structurer && pytest
"""
from __future__ import annotations

from classify import classify_file, write_quarantine_report
from homes import HomeRule
from quarantine import QUARANTINE_REASONS, _iban_valid, _luhn_valid, detect_quarantine


# ---------------------------------------------------------------------------
# quarantine.py — detectors
# ---------------------------------------------------------------------------

def test_no_signal_returns_none():
    assert detect_quarantine("just a regular note about my day", "note.md", {}) is None


def test_vendor_secret_pattern_detected():
    result = detect_quarantine("aws key: AK" "IAABCDEFGHIJ12345K", "note.md", {})
    assert result == {"reason": "secret", "excluded_from_generation": True, "detected_by": "known-vendor-format"}


def test_pem_private_key_header_detected():
    text = "-----BEGIN" " RSA PRIVATE KEY-----\nMIIEow...\n-----END RSA PRIVATE KEY-----"
    result = detect_quarantine(text, "note.md", {})
    assert result["reason"] == "secret"


def test_labeled_high_entropy_assignment_detected():
    result = detect_quarantine('api_key: "aB3xQ9zL2mK7pR4tY8wN"', "note.md", {})
    assert result == {"reason": "secret", "excluded_from_generation": True, "detected_by": "labeled-high-entropy-assignment"}


def test_labeled_placeholder_value_not_flagged():
    assert detect_quarantine("api_key: changeme", "note.md", {}) is None


def test_labeled_ordinary_path_not_flagged():
    # Cold-review finding, 2026-07-15: a length-only check flagged ordinary long
    # values after a "key:"/"token:" label — a file path is not a secret.
    assert detect_quarantine("access_key: my-bucket/path/to/object/with/long/key/name", "note.md", {}) is None


def test_labeled_ordinary_phrase_not_flagged():
    assert detect_quarantine("secret: this-is-a-fairly-long-dashed-phrase-not-a-real-secret", "note.md", {}) is None


def test_luhn_valid_card_number_detected():
    # 4111111111111111 — well-known Luhn-valid test card number
    result = detect_quarantine("card on file: 4111 1111 1111 1111", "note.md", {})
    assert result == {"reason": "payment", "excluded_from_generation": True, "detected_by": "luhn-valid-card-number"}


def test_luhn_invalid_digit_string_not_flagged():
    # Same length as a card number, fails the Luhn checksum — e.g. a random ID.
    assert detect_quarantine("order id: 1234567890123456", "note.md", {}) is None


def test_iban_valid_detected():
    # GB29NWBK60161331926819 — textbook-example valid IBAN (mod-97 checksum passes)
    result = detect_quarantine("wire to GB29NWBK60161331926819", "note.md", {})
    assert result == {"reason": "payment", "excluded_from_generation": True, "detected_by": "iban-checksum"}


def test_iban_shaped_but_invalid_checksum_not_flagged():
    assert detect_quarantine("ref code AB12CDEFGHIJKLMNOP", "note.md", {}) is None


def test_luhn_algorithm_directly():
    assert _luhn_valid("4111111111111111") is True
    assert _luhn_valid("1234567890123456") is False


def test_iban_algorithm_directly():
    assert _iban_valid("GB29NWBK60161331926819") is True
    assert _iban_valid("AB12CDEFGHIJKLMNOP") is False


# ---------------------------------------------------------------------------
# quarantine.py — escape hatch + forced flag
# ---------------------------------------------------------------------------

def test_frontmatter_quarantine_false_overrides_secret_match():
    frontmatter = {"quarantine": False}
    assert detect_quarantine("AK" "IAABCDEFGHIJ12345K", "note.md", frontmatter) is None


def test_frontmatter_speakers_third_party_forces_quarantine():
    frontmatter = {"speakers_third_party": True}
    result = detect_quarantine("nothing suspicious here", "note.md", frontmatter)
    assert result == {"reason": "third-party-pii", "excluded_from_generation": True, "detected_by": "forced-flag"}


def test_forced_flag_wins_over_escape_hatch_when_both_present():
    # Contradictory frontmatter — forced flag is checked first, deliberately: a human
    # saying "this must stay quarantined" should not be silently overridden by a
    # separately-set "quarantine: false" from an earlier edit.
    frontmatter = {"quarantine": False, "speakers_third_party": True}
    result = detect_quarantine("clean text", "note.md", frontmatter)
    assert result is not None
    assert result["reason"] == "third-party-pii"


def test_quoted_string_true_still_forces_quarantine():
    # Cold-review finding, 2026-07-15: `is True` matched only a real YAML bool — a
    # quoted "true" (a plausible habit, since FORMAT.md's own type: examples are
    # quoted) silently failed to trigger the forced flag it's supposed to guarantee.
    frontmatter = {"speakers_third_party": "true"}
    result = detect_quarantine("clean text", "note.md", frontmatter)
    assert result is not None
    assert result["reason"] == "third-party-pii"


def test_quoted_string_false_still_triggers_escape_hatch():
    frontmatter = {"quarantine": "false"}
    assert detect_quarantine("AK" "IAABCDEFGHIJ12345K", "note.md", frontmatter) is None


def test_unrecognized_boolean_value_ignored_not_crashed():
    # A stray "1" (not a YAML bool, not a recognized string) must degrade to "no
    # signal", same tolerance the codebase already applies to malformed frontmatter
    # elsewhere — not a crash, and not a silent misfire in either direction.
    frontmatter = {"speakers_third_party": 1}
    result = detect_quarantine("clean text", "note.md", frontmatter)
    assert result is None


# ---------------------------------------------------------------------------
# classify.py — pipeline integration (quarantine runs before homes.yaml)
# ---------------------------------------------------------------------------

def test_homes_typed_file_still_quarantined_if_secret_inside(tmp_path):
    # Regression case requested in peer-session 2026-07-15-01 (Kimi, turn 1, item 3):
    # homes.yaml assigning a type must not shortcut the quarantine check.
    (tmp_path / "daily-notes").mkdir()
    f = tmp_path / "daily-notes" / "2026-06-01.md"
    f.write_text("today's standup notes.\naws key: AK" "IAABCDEFGHIJ12345K\n")
    homes = [HomeRule("daily-notes/**", "2.2")]

    result = classify_file("daily-notes/2026-06-01.md", str(f), homes)

    assert result["type"] is None
    assert result["quarantine"]["reason"] == "secret"


def test_clean_file_under_homes_rule_still_typed_normally(tmp_path):
    (tmp_path / "daily-notes").mkdir()
    f = tmp_path / "daily-notes" / "2026-06-01.md"
    f.write_text("today's standup notes. nothing sensitive.\n")
    homes = [HomeRule("daily-notes/**", "2.2")]

    result = classify_file("daily-notes/2026-06-01.md", str(f), homes)

    assert result == {"type": "2.2", "mode": "index", "confidence": 1.0, "source": "homes"}


def test_non_text_file_skips_quarantine_scan(tmp_path):
    # No media preprocessor in this slice — quarantine cannot see content that hasn't
    # been extracted yet. A secret-shaped string in a binary's raw bytes is not scanned.
    f = tmp_path / "photo.png"
    f.write_bytes(b"AK" b"IAABCDEFGHIJ12345K")  # would match if it were ever read as text

    result = classify_file("photo.png", str(f), [])

    assert result == {"type": None, "pending": "needs-extractor"}


def test_every_detector_reason_is_a_recognized_enum_value():
    # Regression guard against a typo drifting a hardcoded reason string (e.g.
    # "secert") away from FORMAT.md §4a's enum — every path that can actually
    # produce a `reason` today, exercised together.
    samples = [
        ("AK" "IAABCDEFGHIJ12345K", "note.md", {}),
        ("card: 4111 1111 1111 1111", "note.md", {}),
        ("clean", "note.md", {"speakers_third_party": True}),
    ]
    for text, rel_path, frontmatter in samples:
        result = detect_quarantine(text, rel_path, frontmatter)
        assert result is not None
        assert result["reason"] in QUARANTINE_REASONS


# ---------------------------------------------------------------------------
# classify.py — quarantine-report.md
# ---------------------------------------------------------------------------

def test_quarantine_report_lists_reasons(tmp_path):
    files = {
        "secrets.md": {"type": None, "quarantine": {"reason": "secret", "excluded_from_generation": True, "detected_by": "known-vendor-format"}},
        "clean.md": {"type": "2.4", "mode": "index", "confidence": 0.0, "source": "default"},
    }
    out = tmp_path / "quarantine-report.md"

    count = write_quarantine_report(files, str(out))

    assert count == 1
    text = out.read_text()
    assert "secrets.md" in text
    assert "secret" in text
    assert "clean.md" not in text


def test_quarantine_report_written_even_when_empty(tmp_path):
    out = tmp_path / "quarantine-report.md"

    count = write_quarantine_report({"clean.md": {"type": "2.4"}}, str(out))

    assert count == 0
    assert out.exists()
    assert "No files quarantined" in out.read_text()
