"""
Recommendation registry: raw-v0 contract, delivery events, and the recommendation
lifecycle state machine.

Consensus from the WP-521 peer session (Claude + Kimi + Codex, 2026-10-17):
contract_version `raw-v0` was fixed in an earlier session this same day; this module
is the F14 integration layer that session deferred -- the state machine owner for
a recommendation's path from candidate to a confirmed, idempotent delivery event.

Scope deliberately excludes a candidate_builder (mapping existing selection output
into RawV0Candidate): the peer session found no verified field-provenance mapping
from the current selection code (planner.py / source_finder.py) to raw-v0's five
fields, and blocked that work on a separate provenance audit. This module covers
the two components the session did NOT block: the registry state machine and the
event emitter.
"""

import hashlib
import re
import sqlite3
import threading
import unicodedata
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

RAW_V0_VERSION = "raw-v0"

CREATED = "created"
GROUNDING_CHECKED = "grounding_checked"
SHOWN = "shown"
ISSUED = "issued"
EXPIRED = "expired"
FAILED = "failed"


def compute_content_hash(payload: str) -> str:
    """
    Canonical raw-v0.content_hash: NFC-normalize, collapse whitespace, hash the
    result before any metadata (contract_version, source_ref, ...) is attached.
    Rule fixed by the peer session this same day, reused here unchanged.
    """
    normalized = unicodedata.normalize("NFC", payload)
    collapsed = re.sub(r"\s+", " ", normalized).strip()
    digest = hashlib.sha256(collapsed.encode("utf-8")).hexdigest()
    return f"sha256:{digest}"


@dataclass
class RawV0Candidate:
    """A recommendation candidate in the raw-v0 contract shape."""

    source_ref_type: str
    source_ref_ref: str
    selection_basis: str
    content_hash: str
    topic_ref: Optional[str] = None
    contract_version: str = RAW_V0_VERSION

    def to_dict(self) -> dict:
        return {
            "contract_version": self.contract_version,
            "source_ref": {"type": self.source_ref_type, "ref": self.source_ref_ref},
            "selection_basis": self.selection_basis,
            "topic_ref": self.topic_ref,
            "content_hash": self.content_hash,
        }


@dataclass
class RecommendationIssued:
    """Thin pointer event: the recommendation was delivered and delivery was confirmed."""

    recommendation_ref: str
    raw_ref: str
    surface: str
    issued_at: str
    session_ref: Optional[str] = None


@dataclass
class RecommendationExpired:
    """The recommendation was shown but delivery was never confirmed before its TTL."""

    recommendation_ref: str
    raw_ref: str
    expired_at: str


@dataclass
class RecommendationFailed:
    """Grounding or rendering failed before the recommendation reached the user."""

    recommendation_ref: str
    raw_ref: str
    stage: str  # "grounding" | "render"
    failed_at: str
    reason: str = ""


class TransitionRejected(Exception):
    """A state transition's precondition did not hold: unknown ref or wrong starting state."""


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class RecommendationRegistry:
    """
    Reference implementation of the recommendation lifecycle:
    created -> grounding_checked -> shown -> issued | expired,
    with failed reachable from created (grounding stage) or grounding_checked
    (render stage).

    Backed by SQLite so the CAS transitions below are real `UPDATE ... WHERE
    state = <expected>` statements, not just in-process locking -- the peer
    session's point was that atomicity must come from checking the row's
    current state, not merely wrapping the write in a transaction. Where this
    registry physically lives in production (this SQLite file vs. the
    platform's own database) was explicitly left to a separate infra check by
    that session; swap the storage by replacing this class while keeping its
    method contract (CAS semantics, event return values).

    `db_path` has no default on purpose: callers must say explicitly where the
    registry lives. A silent `:memory:` default would let two instances (e.g.
    one per worker thread) end up with two disconnected databases that never
    see each other's writes -- confirm_issued's dedup would then silently stop
    working, not fail loudly. Tests pass ":memory:" explicitly.

    Thread-safe for use from multiple threads against one instance: each
    public method serializes through `self._lock`, and the connection is
    opened with `check_same_thread=False` to allow that.
    """

    def __init__(self, db_path: str):
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(db_path, check_same_thread=False)
        self._conn.execute(
            """
            CREATE TABLE IF NOT EXISTS recommendation (
                recommendation_ref TEXT PRIMARY KEY,
                raw_ref TEXT NOT NULL,
                state TEXT NOT NULL
            )
            """
        )
        self._conn.commit()

    def close(self) -> None:
        self._conn.close()

    def create(self, raw_ref: str) -> str:
        """Start a new recommendation attempt in state `created`. Returns its recommendation_ref."""
        recommendation_ref = str(uuid.uuid4())
        with self._lock:
            self._conn.execute(
                "INSERT INTO recommendation (recommendation_ref, raw_ref, state) VALUES (?, ?, ?)",
                (recommendation_ref, raw_ref, CREATED),
            )
            self._conn.commit()
        return recommendation_ref

    def _row(self, recommendation_ref: str) -> tuple:
        row = self._conn.execute(
            "SELECT raw_ref, state FROM recommendation WHERE recommendation_ref = ?",
            (recommendation_ref,),
        ).fetchone()
        if row is None:
            raise TransitionRejected(f"{recommendation_ref}: unknown recommendation_ref")
        return row

    def _cas(self, recommendation_ref: str, expected_state: str, next_state: str) -> bool:
        cur = self._conn.execute(
            "UPDATE recommendation SET state = ? WHERE recommendation_ref = ? AND state = ?",
            (next_state, recommendation_ref, expected_state),
        )
        self._conn.commit()
        return cur.rowcount == 1

    def state_of(self, recommendation_ref: str) -> str:
        with self._lock:
            return self._row(recommendation_ref)[1]

    def mark_grounding_checked(self, recommendation_ref: str) -> None:
        with self._lock:
            self._row(recommendation_ref)  # raises on unknown ref
            if not self._cas(recommendation_ref, CREATED, GROUNDING_CHECKED):
                raise TransitionRejected(f"{recommendation_ref}: expected state {CREATED}")

    def mark_shown(self, recommendation_ref: str) -> None:
        with self._lock:
            self._row(recommendation_ref)
            if not self._cas(recommendation_ref, GROUNDING_CHECKED, SHOWN):
                raise TransitionRejected(f"{recommendation_ref}: expected state {GROUNDING_CHECKED}")

    def confirm_issued(
        self, recommendation_ref: str, surface: str, session_ref: Optional[str] = None
    ) -> Optional[RecommendationIssued]:
        """
        Idempotent delivery confirmation: SHOWN -> ISSUED.

        Returns the event on the call that wins the CAS. Returns None (no new
        event) when the ref is already ISSUED -- a retried confirm after the
        transition already landed -- or when it lost the race to `expire()`.
        """
        with self._lock:
            raw_ref, state = self._row(recommendation_ref)
            if state == ISSUED:
                return None
            if not self._cas(recommendation_ref, SHOWN, ISSUED):
                return None
        return RecommendationIssued(
            recommendation_ref=recommendation_ref,
            raw_ref=raw_ref,
            surface=surface,
            issued_at=_utc_now_iso(),
            session_ref=session_ref,
        )

    def expire(self, recommendation_ref: str) -> Optional[RecommendationExpired]:
        """TTL sweep: SHOWN -> EXPIRED. Returns None if it lost the race to confirm_issued()."""
        with self._lock:
            raw_ref, _state = self._row(recommendation_ref)
            if not self._cas(recommendation_ref, SHOWN, EXPIRED):
                return None
        return RecommendationExpired(
            recommendation_ref=recommendation_ref, raw_ref=raw_ref, expired_at=_utc_now_iso()
        )

    def mark_failed(self, recommendation_ref: str, stage: str, reason: str = "") -> RecommendationFailed:
        """stage="grounding": created->failed. stage="render": grounding_checked->failed."""
        if stage not in ("grounding", "render"):
            raise ValueError(f"unknown stage: {stage!r}")
        expected = CREATED if stage == "grounding" else GROUNDING_CHECKED
        with self._lock:
            raw_ref, _state = self._row(recommendation_ref)
            if not self._cas(recommendation_ref, expected, FAILED):
                raise TransitionRejected(f"{recommendation_ref}: expected state {expected} for stage={stage}")
        return RecommendationFailed(
            recommendation_ref=recommendation_ref,
            raw_ref=raw_ref,
            stage=stage,
            failed_at=_utc_now_iso(),
            reason=reason,
        )
