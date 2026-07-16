#!/usr/bin/env python3
# check-manifest-coverage.py — проверяет что все файлы репо покрыты update-manifest.json
# Использование: git ls-files | python3 scripts/check-manifest-coverage.py update-manifest.json
# Exit 0 = всё покрыто. Exit 1 = файлы без покрытия (B2 gap). Exit 2 = ошибка вызова.
#
# Файлы без покрытия = в git, но не в manifest["files"] и не в exclusions.
# Исправление: добавить в manifest["files"] или manifest["excluded_paths"].
# excluded_paths принимает список строк: ["path/to/file.md", ...]
#
# issue #247: update.sh (step 6e) replaces update-manifest.json wholesale on
# every update, so user edits to excluded_paths do not survive. Fork-local
# exclusions belong in update-manifest.local.json (same directory, same
# excluded_paths schema) — update.sh never touches it, this checker merges it.

from __future__ import annotations

import sys
import json
from pathlib import Path


# Файлы/папки, намеренно не включаемые в manifest:
# - .github/        — CI/CD, не доставляется пользователям
# - setup/          — install-time скрипты
# - seed/           — scaffold-шаблоны (только при первом install)
# - templates/      — scaffold-шаблоны (только при первом install)
# - extensions/     — пользовательские кастомизации, не перезаписываются
# - params.yaml     — пользовательский конфиг (авторский)
# - generate-manifest.sh / update-manifest.json — инструментарий манифеста
# - README.md / LICENSE / CONTRIBUTING.md / CHANGELOG.md / CODE_OF_CONDUCT.md /
#   SECURITY.md / PRIVACY.md / CODEOWNERS / CITATION.cff — мета репо (только корень)
# - .gitkeep        — маркеры пустых папок
# - .DS_Store       — мусор macOS

# Имена файлов, исключаемые ТОЛЬКО когда они в корне репо (len(parts)==1).
# Платформенные README.md, CHANGELOG.md в подпапках (roles/*/README.md) — в манифесте,
# и если новый добавить, не забыть добавить в манифест → CI должен это поймать.
_ROOT_ONLY_EXCLUDED_NAMES = frozenset({
    "README.md",
    "README.en.md",
    "CONTRIBUTING.md",
    "LICENSE",
    "CHANGELOG.md",
    "CODE_OF_CONDUCT.md",
    "SECURITY.md",
    "PRIVACY.md",
    "CODEOWNERS",
    "CITATION.cff",
})

# Имена файлов, исключаемые везде независимо от папки.
_ALWAYS_EXCLUDED_NAMES = frozenset({
    ".DS_Store",
    ".gitkeep",
    "params.yaml",
    "generate-manifest.sh",
    "update-manifest.json",
    "update-manifest.local.json",
})

# Точные пути для исключения.
_EXCLUDED_EXACT_PATHS = frozenset({
    ".claude/settings.local.json",
})

# Верхнеуровневые папки: весь контент исключается.
_EXCLUDED_TOP_DIRS = frozenset({
    ".github",
    "setup",
    "seed",
    "templates",
    "extensions",
})


def _is_excluded(path: str, extra: list[str]) -> bool:
    p = Path(path)
    parts = p.parts

    if p.name in _ALWAYS_EXCLUDED_NAMES:
        return True

    # Корневые мета-файлы: исключать только если они прямо в корне репо
    if len(parts) == 1 and p.name in _ROOT_ONLY_EXCLUDED_NAMES:
        return True

    if path in _EXCLUDED_EXACT_PATHS:
        return True

    if parts and parts[0] in _EXCLUDED_TOP_DIRS:
        return True

    if path in extra:
        return True

    for exc in extra:
        exc_norm = exc.rstrip("/")
        if path.startswith(exc_norm + "/") or path == exc_norm:
            return True

    return False


def _parse_excluded_paths(raw: object) -> list[str]:
    """Принимает список строк или список dict'ов {"path": "..."} → список строк."""
    if not isinstance(raw, list):
        return []
    result = []
    for item in raw:
        if isinstance(item, str):
            result.append(item)
        elif isinstance(item, dict) and "path" in item:
            result.append(item["path"])
    return result


def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: git ls-files | python3 check-manifest-coverage.py <manifest.json>",
              file=sys.stderr)
        sys.exit(2)

    manifest_path = sys.argv[1]
    try:
        with open(manifest_path, encoding="utf-8") as fh:
            manifest = json.load(fh)
    except FileNotFoundError:
        print(f"ERROR: manifest not found: {manifest_path}", file=sys.stderr)
        sys.exit(2)

    manifest_files = {entry["path"] for entry in manifest.get("files", [])}
    deprecated_files = {entry["path"] for entry in manifest.get("deprecated_files", [])}
    extra_exclusions = _parse_excluded_paths(manifest.get("excluded_paths", []))

    # Fork-local exclusions survive update.sh (which replaces the main manifest
    # wholesale at step 6e). Malformed JSON is a loud error, not a silent skip:
    # otherwise a typo would silently re-enable blocking on excluded files.
    local_path = Path(manifest_path).parent / "update-manifest.local.json"
    if local_path.is_file():
        try:
            with open(local_path, encoding="utf-8") as fh:
                local_manifest = json.load(fh)
        except json.JSONDecodeError as exc:
            print(f"ERROR: {local_path} is not valid JSON: {exc}", file=sys.stderr)
            sys.exit(2)
        extra_exclusions += _parse_excluded_paths(
            local_manifest.get("excluded_paths", [])
        )

    repo_files = [line.strip() for line in sys.stdin if line.strip()]

    if not repo_files:
        print("ERROR: stdin пуст — git ls-files не вернул файлов (пустой репо или ошибка пайпа)",
              file=sys.stderr)
        sys.exit(2)

    gaps = []
    excluded_count = 0
    deprecated_count = 0
    for f in repo_files:
        if f in manifest_files:
            continue
        if f in deprecated_files:
            deprecated_count += 1
            continue
        if _is_excluded(f, extra_exclusions):
            excluded_count += 1
            continue
        gaps.append(f)

    if gaps:
        print(
            f"❌ manifest-coverage: {len(gaps)} файл(ов) есть в репо, но не в {manifest_path}:",
            file=sys.stderr,
        )
        for g in sorted(gaps):
            print(f"  {g}", file=sys.stderr)
        print(
            '  → Добавить в manifest["files"] или manifest["excluded_paths"];\n'
            "    личные файлы форка — в update-manifest.local.json "
            '("excluded_paths": [...]), его update.sh не перезаписывает',
            file=sys.stderr,
        )
        sys.exit(1)

    total = len(repo_files)
    in_manifest = len(manifest_files)
    print(
        f"✅ manifest-coverage: все {total} repo-файлов покрыты "
        f"(manifest={in_manifest}, excluded={excluded_count}, deprecated_in_repo={deprecated_count})"
    )


if __name__ == "__main__":
    main()
