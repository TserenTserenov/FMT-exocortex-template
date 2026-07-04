#!/usr/bin/env python3
# check-manifest-rename-coverage.py — issue #218: находит пути, пропавшие из
# files[] между двумя версиями манифеста без записи в deprecated_files[].
# Использование: python3 scripts/check-manifest-rename-coverage.py <old.json> <new.json>
# Exit 0 = все прежние пути учтены (остались активными или помечены deprecated).
# Exit 1 = найдены пути-сироты. Exit 2 = ошибка вызова/чтения файлов.
#
# Причина: generate-manifest.sh копирует deprecated_files из прошлой версии
# без изменений и строит files[] заново из git ls-files — между списками нет
# автосверки, поэтому переименование без ручной правки deprecated_files[]
# оставляет старый путь сиротой навсегда у уже установивших пилотов.

from __future__ import annotations

import json
import sys
from pathlib import Path


def load_paths(manifest_path: str, key: str) -> set[str]:
    with open(manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)
    entries = manifest.get(key, [])
    return {e["path"] if isinstance(e, dict) else e for e in entries}


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: check-manifest-rename-coverage.py <old-manifest.json> <new-manifest.json>", file=sys.stderr)
        return 2

    old_path, new_path = sys.argv[1], sys.argv[2]
    if not Path(old_path).is_file() or not Path(new_path).is_file():
        print(f"ERROR: manifest not found ({old_path} / {new_path})", file=sys.stderr)
        return 2

    old_files = load_paths(old_path, "files")
    new_known = load_paths(new_path, "files") | load_paths(new_path, "deprecated_files")

    orphans = sorted(old_files - new_known)

    if orphans:
        print(f"FAIL: {len(orphans)} путь(-и/-ей) пропали из files[] без записи в deprecated_files[]:", file=sys.stderr)
        for p in orphans:
            print(f"  {p}", file=sys.stderr)
        print("", file=sys.stderr)
        print("Если это переименование — добавь старый путь в deprecated_files[] нового манифеста.", file=sys.stderr)
        print("Если файл удалён навсегда — то же самое (deprecated_files[] покрывает оба случая).", file=sys.stderr)
        return 1

    print(f"OK: {len(old_files)} путей из прошлой версии учтены (активны или deprecated)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
