"""Persistent storage and querying of consent state for data needs."""

import os
import yaml
from pathlib import Path
from typing import Dict, Optional, Literal
from datetime import datetime


ConsentStatus = Literal["not_asked", "granted", "denied", "revoked"]


class ResidencyState:
    """Manages persistent data-residency.yaml state in current/ directory."""

    def __init__(self, state_file: Optional[str] = None):
        """Initialize state manager.

        Args:
            state_file: Path to data-residency.yaml (defaults to ~/IWE/current/data-residency.yaml)
        """
        if state_file is None:
            iwe_home = os.path.expanduser("~/IWE")
            state_file = os.path.join(iwe_home, "current", "data-residency.yaml")

        self.state_file = Path(state_file)
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        self._ensure_file_exists()

    def _ensure_file_exists(self) -> None:
        """Create empty state file if it doesn't exist."""
        if not self.state_file.exists():
            self._save_state({})

    def _load_state(self) -> dict:
        """Load current state from yaml."""
        try:
            content = self.state_file.read_text()
            doc = yaml.safe_load(content) or {}
            return doc.get("functions") or {}
        except (OSError, IOError, yaml.YAMLError):
            return {}

    def _save_state(self, state: dict) -> None:
        """Save state to yaml file atomically."""
        doc = {"functions": state}
        header = "# Data residency consent state\n# Auto-generated\n\n"
        content = header + yaml.safe_dump(doc, default_flow_style=False, sort_keys=True, allow_unicode=True)

        tmp_file = self.state_file.with_suffix('.tmp')
        tmp_file.write_text(content)
        tmp_file.replace(self.state_file)

    def get_consent(self, function_id: str, data_need_key: str) -> Dict:
        """Get current consent status for a specific data need.

        Returns dict with keys:
        - status: ConsentStatus
        - granted_at: ISO timestamp or null
        - denied_reason: string or null
        """
        state = self._load_state()
        func_state = state.get(function_id, {})
        need_state = func_state.get(data_need_key, {})

        return {
            "status": need_state.get("status", "not_asked"),
            "granted_at": need_state.get("granted_at"),
            "denied_reason": need_state.get("denied_reason"),
        }

    def grant_consent(self, function_id: str, data_need_key: str) -> None:
        """Record user grant for a data need."""
        state = self._load_state()
        if function_id not in state:
            state[function_id] = {}

        state[function_id][data_need_key] = {
            "status": "granted",
            "granted_at": datetime.utcnow().isoformat() + "Z",
        }
        self._save_state(state)

    def deny_consent(self, function_id: str, data_need_key: str, reason: str = "") -> None:
        """Record user denial for a data need."""
        state = self._load_state()
        if function_id not in state:
            state[function_id] = {}

        state[function_id][data_need_key] = {
            "status": "denied",
            "denied_reason": reason,
            "denied_at": datetime.utcnow().isoformat() + "Z",
        }
        self._save_state(state)

    def revoke_consent(self, function_id: str, data_need_key: str, reason: str = "") -> None:
        """User revokes previously granted consent."""
        state = self._load_state()
        if function_id not in state:
            state[function_id] = {}

        state[function_id][data_need_key] = {
            "status": "revoked",
            "revoked_reason": reason,
            "revoked_at": datetime.utcnow().isoformat() + "Z",
        }
        self._save_state(state)

    def list_all_consents(self) -> Dict:
        """Return all consent records."""
        return self._load_state()

    def reset_function_consents(self, function_id: str) -> None:
        """Clear all consent records for a function (for version upgrade/reset)."""
        state = self._load_state()
        state.pop(function_id, None)
        self._save_state(state)
