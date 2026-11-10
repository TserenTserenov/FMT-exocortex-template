"""
Tests for recommendation_registry.py: raw-v0 hash, lifecycle transitions, and the
CAS races the WP-521 peer session (2026-10-17) flagged -- confirm vs expiry,
idempotent confirm, failed from each blocked stage.
"""

import threading

import pytest

from recommendation_registry import (
    EXPIRED,
    FAILED,
    GROUNDING_CHECKED,
    ISSUED,
    SHOWN,
    RawV0Candidate,
    RecommendationExpired,
    RecommendationFailed,
    RecommendationIssued,
    RecommendationRegistry,
    TransitionRejected,
    compute_content_hash,
)


class TestComputeContentHash:
    def test_deterministic(self):
        assert compute_content_hash("hello world") == compute_content_hash("hello world")

    def test_sha256_prefix(self):
        assert compute_content_hash("x").startswith("sha256:")

    def test_collapses_whitespace(self):
        assert compute_content_hash("a   b\n\nc") == compute_content_hash("a b c")

    def test_nfc_normalizes_unicode(self):
        # "é" as a single precomposed codepoint vs. "e" + a combining acute accent
        # (decomposed form) -- same text, different bytes.
        decomposed = "é"
        precomposed = "é"
        assert compute_content_hash(decomposed) == compute_content_hash(precomposed)

    def test_different_payload_different_hash(self):
        assert compute_content_hash("a") != compute_content_hash("b")


class TestRawV0Candidate:
    def test_to_dict_shape(self):
        candidate = RawV0Candidate(
            source_ref_type="club_post",
            source_ref_ref="post-42",
            selection_basis="bottleneck",
            content_hash=compute_content_hash("content"),
            topic_ref="topic-7",
        )
        d = candidate.to_dict()
        assert d["contract_version"] == "raw-v0"
        assert d["source_ref"] == {"type": "club_post", "ref": "post-42"}
        assert d["topic_ref"] == "topic-7"

    def test_topic_ref_defaults_to_none(self):
        candidate = RawV0Candidate(
            source_ref_type="t", source_ref_ref="r", selection_basis="b", content_hash="sha256:x"
        )
        assert candidate.to_dict()["topic_ref"] is None


@pytest.fixture
def registry():
    reg = RecommendationRegistry(":memory:")
    yield reg
    reg.close()


class TestHappyPath:
    def test_full_lifecycle_emits_issued(self, registry):
        ref = registry.create(raw_ref="raw-1")
        assert registry.state_of(ref) == "created"
        registry.mark_grounding_checked(ref)
        assert registry.state_of(ref) == GROUNDING_CHECKED
        registry.mark_shown(ref)
        assert registry.state_of(ref) == SHOWN
        event = registry.confirm_issued(ref, surface="telegram")
        assert isinstance(event, RecommendationIssued)
        assert event.recommendation_ref == ref
        assert event.raw_ref == "raw-1"
        assert event.surface == "telegram"
        assert registry.state_of(ref) == ISSUED

    def test_confirm_issued_is_idempotent(self, registry):
        ref = registry.create(raw_ref="raw-1")
        registry.mark_grounding_checked(ref)
        registry.mark_shown(ref)
        first = registry.confirm_issued(ref, surface="telegram")
        second = registry.confirm_issued(ref, surface="telegram")
        assert first is not None
        assert second is None  # already issued -- no duplicate event
        assert registry.state_of(ref) == ISSUED


class TestExpiry:
    def test_expire_from_shown(self, registry):
        ref = registry.create(raw_ref="raw-1")
        registry.mark_grounding_checked(ref)
        registry.mark_shown(ref)
        event = registry.expire(ref)
        assert isinstance(event, RecommendationExpired)
        assert registry.state_of(ref) == EXPIRED

    def test_confirm_after_expiry_is_noop(self, registry):
        ref = registry.create(raw_ref="raw-1")
        registry.mark_grounding_checked(ref)
        registry.mark_shown(ref)
        registry.expire(ref)
        result = registry.confirm_issued(ref, surface="telegram")
        assert result is None  # lost the race -- expired wins, no issued event
        assert registry.state_of(ref) == EXPIRED

    def test_expire_after_issued_is_noop(self, registry):
        ref = registry.create(raw_ref="raw-1")
        registry.mark_grounding_checked(ref)
        registry.mark_shown(ref)
        registry.confirm_issued(ref, surface="telegram")
        result = registry.expire(ref)
        assert result is None  # lost the race -- issued wins, no expired event
        assert registry.state_of(ref) == ISSUED


class TestFailure:
    def test_grounding_failure_from_created(self, registry):
        ref = registry.create(raw_ref="raw-1")
        event = registry.mark_failed(ref, stage="grounding", reason="no grounding gate wiring")
        assert isinstance(event, RecommendationFailed)
        assert event.stage == "grounding"
        assert registry.state_of(ref) == FAILED

    def test_render_failure_from_grounding_checked(self, registry):
        ref = registry.create(raw_ref="raw-1")
        registry.mark_grounding_checked(ref)
        event = registry.mark_failed(ref, stage="render", reason="surface timeout")
        assert event.stage == "render"
        assert registry.state_of(ref) == FAILED

    def test_render_failure_rejected_before_grounding_checked(self, registry):
        ref = registry.create(raw_ref="raw-1")
        with pytest.raises(TransitionRejected):
            registry.mark_failed(ref, stage="render")

    def test_unknown_stage_rejected(self, registry):
        ref = registry.create(raw_ref="raw-1")
        with pytest.raises(ValueError):
            registry.mark_failed(ref, stage="bogus")


class TestInvalidTransitions:
    def test_shown_before_grounding_checked_rejected(self, registry):
        ref = registry.create(raw_ref="raw-1")
        with pytest.raises(TransitionRejected):
            registry.mark_shown(ref)

    def test_confirm_before_shown_is_noop(self, registry):
        ref = registry.create(raw_ref="raw-1")
        registry.mark_grounding_checked(ref)
        assert registry.confirm_issued(ref, surface="telegram") is None
        assert registry.state_of(ref) == GROUNDING_CHECKED

    def test_unknown_ref_raises(self, registry):
        with pytest.raises(TransitionRejected):
            registry.state_of("does-not-exist")


class TestConcurrency:
    """Real multi-threaded races against one shared registry instance (review finding High-2)."""

    def test_concurrent_confirm_issued_wins_exactly_once(self, registry):
        ref = registry.create(raw_ref="raw-1")
        registry.mark_grounding_checked(ref)
        registry.mark_shown(ref)

        results = []
        barrier = threading.Barrier(20)

        def attempt():
            barrier.wait()
            results.append(registry.confirm_issued(ref, surface="telegram"))

        threads = [threading.Thread(target=attempt) for _ in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        winners = [r for r in results if r is not None]
        assert len(winners) == 1
        assert registry.state_of(ref) == ISSUED

    def test_concurrent_confirm_and_expire_exactly_one_wins(self, registry):
        ref = registry.create(raw_ref="raw-1")
        registry.mark_grounding_checked(ref)
        registry.mark_shown(ref)

        outcomes = []
        barrier = threading.Barrier(2)

        def confirm():
            barrier.wait()
            outcomes.append(("confirm", registry.confirm_issued(ref, surface="telegram")))

        def expire():
            barrier.wait()
            outcomes.append(("expire", registry.expire(ref)))

        threads = [threading.Thread(target=confirm), threading.Thread(target=expire)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        wins = [(kind, event) for kind, event in outcomes if event is not None]
        assert len(wins) == 1
        final_state = registry.state_of(ref)
        assert final_state in (ISSUED, EXPIRED)
        assert wins[0][0] == ("confirm" if final_state == ISSUED else "expire")
