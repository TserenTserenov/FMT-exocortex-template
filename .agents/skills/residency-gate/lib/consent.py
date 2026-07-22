"""ResidencyGate consent controller - Point A (activation) and Point B (lazy)."""

import warnings
from pathlib import Path
from typing import Dict, List, Tuple, Optional, Callable

import yaml

from .parser import DataNeed
from .state import ResidencyState, ConsentStatus


DEFAULT_PRE_GRANT_FILE = Path(__file__).parent.parent / "pre-grant.yaml"


class PreGrantError(ValueError):
    """Pre-grant list is malformed; the gate must fail closed, not guess."""


def load_pre_grant_entries(path: Optional[Path] = None) -> Dict[str, dict]:
    """Load and validate the install-time pre-grant list.

    Every entry must carry an explicit pilot approval (approved_by: pilot +
    approved_at date) — an unapproved entry is a blocking error, not a warning
    (pilot decision 2026-07-16, WP-475 acceptance criterion 6).

    Returns {function_id: entry}. Missing file → empty dict (nothing pre-granted).
    """
    path = path or DEFAULT_PRE_GRANT_FILE
    if not path.exists():
        return {}
    doc = yaml.safe_load(path.read_text()) or {}
    entries: Dict[str, dict] = {}
    for i, entry in enumerate(doc.get("pre_granted") or []):
        function_id = entry.get("function_id")
        if not function_id:
            raise PreGrantError(f"pre-grant entry #{i} has no function_id")
        if entry.get("approved_by") != "pilot":
            raise PreGrantError(
                f"pre-grant entry '{function_id}' lacks 'approved_by: pilot' — a new "
                f"inbound consumer enters the pre-grant list only with explicit pilot approval"
            )
        if not entry.get("approved_at"):
            raise PreGrantError(f"pre-grant entry '{function_id}' lacks approved_at date")
        entries[function_id] = entry
    return entries


class ResidencyGate:
    """Single controller for all residency consent checks."""

    def __init__(
        self,
        state_manager: Optional[ResidencyState] = None,
        pre_grant_file: Optional[Path] = None,
    ):
        self.state = state_manager or ResidencyState()
        self._pre_grant_file = pre_grant_file
        self._pre_grant_entries: Optional[Dict[str, dict]] = None  # loaded lazily

    def _pre_grants(self) -> Dict[str, dict]:
        """Pre-grant entries from the durable file; raises PreGrantError on a malformed list."""
        if self._pre_grant_entries is None:
            self._pre_grant_entries = load_pre_grant_entries(self._pre_grant_file)
        return self._pre_grant_entries

    def mark_pre_granted(self, function_id: str) -> None:
        """Deprecated no-op: programmatic self-marking is no longer honored.

        Pre-grant comes only from the pilot-approved pre-grant.yaml (WP-476 F1
        condition 6). Kept callable so pre-2026-07-16 consumers don't crash on
        repo-version skew; it grants nothing.
        """
        warnings.warn(
            f"mark_pre_granted('{function_id}') is a no-op — add the function to "
            f"pre-grant.yaml with explicit pilot approval instead",
            DeprecationWarning,
            stacklevel=2,
        )

    def _is_pre_granted(self, function_id: str, need: DataNeed) -> bool:
        """Pre-grant applies only to inbound flows explicitly listed by the pilot.

        Outbound flows can never be pre-granted at install time (WP-475
        acceptance criterion 6). An entry may narrow itself to specific need
        keys via its optional 'needs' list.
        """
        entry = self._pre_grants().get(function_id)
        if entry is None or need.flow_direction != "inbound":
            return False
        allowed = entry.get("needs")
        return allowed is None or need.key() in allowed

    def check_activation(
        self,
        function_id: str,
        data_needs: List[DataNeed],
        on_new_need: Optional[Callable[[str, DataNeed], bool]] = None,
    ) -> Tuple[bool, List[str]]:
        """Point A: Check consent at activation time (function startup).

        Returns:
            (allow_activation, blocking_reasons)
            - allow_activation: True if all needs are either granted or pre-granted
            - blocking_reasons: list of reasons why activation would be blocked
        """
        blocking = []

        for need in data_needs:
            need_key = need.key()
            consent = self.state.get_consent(function_id, need_key)
            status = consent["status"]

            if status == "granted":
                continue
            elif status == "denied":
                reason = consent.get("denied_reason", "user denied")
                blocking.append(f"{need.name}: {reason}")
            elif status == "revoked":
                blocking.append(f"{need.name}: consent revoked by user")
            elif status == "not_asked":
                if self._is_pre_granted(function_id, need):
                    self.state.grant_consent(function_id, need_key)
                    continue
                blocking.append(f"{need.name}: requires consent (use Point B / lazy check)")

        return len(blocking) == 0, blocking

    def check_lazy(
        self,
        function_id: str,
        data_need: DataNeed,
        on_deny_callback: Optional[Callable[[str], None]] = None,
    ) -> Tuple[bool, str]:
        """Point B: Check consent at actual use time (lazy, interactive).

        Returns:
            (allow_access, reason)
            - allow_access: True if data can be accessed
            - reason: human-readable status (for logging)
        """
        need_key = data_need.key()
        consent = self.state.get_consent(function_id, need_key)
        status = consent["status"]

        if status == "granted":
            return True, f"Access granted (at {consent.get('granted_at', 'unknown time')})"

        if status == "denied":
            reason = consent.get("denied_reason", "user denied")
            if on_deny_callback:
                on_deny_callback(reason)
            return False, f"Access denied: {reason}"

        if status == "revoked":
            reason = consent.get("revoked_reason", "consent revoked")
            if on_deny_callback:
                on_deny_callback(reason)
            return False, f"Revoked: {reason}"

        return False, "Access not yet consented (status: not_asked)"

    def handle_version_mismatch(
        self, function_id: str, data_needs: List[DataNeed], old_schema_version: int
    ) -> Tuple[bool, List[str]]:
        """Handle schema version change: graceful re-consent for new needs.

        Returns:
            (needs_revalidation, new_needs)
            - needs_revalidation: True if user interaction required
            - new_needs: list of DataNeed with schema_version > old_schema_version
        """
        new_needs = [n for n in data_needs if n.schema_version > old_schema_version]

        if new_needs:
            for need in new_needs:
                self.state.reset_function_consents(function_id)
            return True, new_needs

        return False, []

    def export_consent_record(self, function_id: str) -> dict:
        """Export full consent record for audit/transparency."""
        all_consents = self.state.list_all_consents()
        return all_consents.get(function_id, {})
