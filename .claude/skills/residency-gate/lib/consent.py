"""ResidencyGate consent controller - Point A (activation) and Point B (lazy)."""

from typing import List, Tuple, Optional, Callable
from .parser import DataNeed
from .state import ResidencyState, ConsentStatus


class ResidencyGate:
    """Single controller for all residency consent checks."""

    def __init__(self, state_manager: Optional[ResidencyState] = None):
        self.state = state_manager or ResidencyState()
        self.pre_granted_functions = set()

    def mark_pre_granted(self, function_id: str) -> None:
        """Register a function as pre-granted (install-time approval by user)."""
        self.pre_granted_functions.add(function_id)

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
                if function_id in self.pre_granted_functions:
                    self.state.grant_consent(function_id, need_key)
                    continue
                else:
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
