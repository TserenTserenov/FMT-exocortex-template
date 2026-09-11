#!/usr/bin/env python3
"""peer-adapter-filter.py — .agentigore filter + PII sanity-check.

Called by kimi-peer-adapter.sh / claude-peer-adapter.sh (WP-365 Ф2-Ф3).
See: DP.SC.154, peer-session 2026-05-29-27-wp365-agentigore-pii-filter.

Inputs (env vars):
  AGENTIGORE_FILE — путь к merged .agentigore (gitignore-style patterns)
  SRC_DIR — исходная директория (--add-dir Kimi)
  DST_DIR — целевая чистая директория (создаётся вызывающим)

Exit codes:
  0 — OK
  3 — PII Hard Block (filename или content match)
  иначе — Python traceback (exit 1)
"""
import os
import sys
import fnmatch
import shutil
import re


def main() -> int:
    src = os.environ["SRC_DIR"]
    dst = os.environ["DST_DIR"]
    patterns_file = os.environ["AGENTIGORE_FILE"]

    with open(patterns_file) as f:
        patterns = [
            p.strip()
            for p in f.read().splitlines()
            if p.strip() and not p.startswith("#")
        ]

    # High-severity PII patterns (content scan)
    high_content = [
        rb"Bearer [A-Za-z0-9._/+=-]{20,}",
        rb"sk-[A-Za-z0-9]{20,}",
        rb"ghp_[A-Za-z0-9]{20,}",
        rb"github_pat_[A-Za-z0-9_]{20,}",
        rb"gho_[A-Za-z0-9]{20,}",
        rb"xoxb-[0-9]+-[0-9]+-[A-Za-z0-9]+",
        rb"xoxe-[A-Za-z0-9-]+",
        rb"AKIA[0-9A-Z]{16}",
        rb"AIza[0-9A-Za-z_-]{35}",
        rb"-----BEGIN [A-Z]+ PRIVATE KEY-----",
        rb"[0-9]{8,}:[A-Za-z0-9_-]{35}",  # Telegram bot token
        rb"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+",  # JWT
        rb"(mongodb|postgres|mysql|redis)(\+srv)?://[^:]+:[^@/\s]+@",
        rb"https?://[^:/\s]+:[^@/\s]+@",  # Basic Auth URL
        rb"M[A-Za-z0-9_-]{23}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27}",  # Discord
        rb"(^|[^0-9-])[0-9]{3}-[0-9]{3}-[0-9]{3}\s[0-9]{2}([^0-9]|$)",  # СНИЛС (с boundary)
    ]
    high_content_re = [re.compile(p) for p in high_content]

    high_filename = [
        r"cp_profile_[^/]+\.(json|yaml|md)$",
        r".*@[a-zA-Z0-9.-]+\.(ru|com|net|org)$",
        r".*\.token$",
        r".*-secret\.[a-z]+$",
        r".*\.key$",
        r".*\.pem$",
    ]
    high_filename_re = [re.compile(p) for p in high_filename]

    ip_pattern = re.compile(rb"(^|[^0-9])(([0-9]{1,3}\.){3}[0-9]{1,3})([^0-9]|$)")
    private_ip = re.compile(rb"^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)")

    deep_dir_re = re.compile(r"^\*\*/(.+?)/\*\*$")

    def is_ignored(rel_path: str) -> bool:
        parts = rel_path.split(os.sep)
        base = parts[-1]
        for p in patterns:
            # **/X/** → directory anywhere in path
            m = deep_dir_re.match(p)
            if m:
                target = m.group(1)
                if any(fnmatch.fnmatch(part, target) for part in parts[:-1]):
                    return True
                continue
            # **/X → match basename anywhere OR full path
            if p.startswith("**/"):
                tail = p[3:]
                if fnmatch.fnmatch(base, tail):
                    return True
                if fnmatch.fnmatch(rel_path, tail):
                    return True
                continue
            # X/** → directory prefix
            if p.endswith("/**"):
                prefix = p[:-3]
                if rel_path == prefix or rel_path.startswith(prefix + os.sep):
                    return True
                continue
            # Plain glob — match relative path or basename
            if fnmatch.fnmatch(rel_path, p):
                return True
            if fnmatch.fnmatch(base, p):
                return True
        return False

    pii_count_medium = 0

    MAX_CONTENT_SCAN = 10 * 1024 * 1024  # 10MB (vs prev 1MB — снижает padding-bypass)

    for root, _dirs, files in os.walk(src, followlinks=False):
        rel_root = os.path.relpath(root, src)
        for f in files:
            rel_path = (
                os.path.normpath(os.path.join(rel_root, f)) if rel_root != "." else f
            )
            full_path = os.path.join(root, f)

            # 0) Path traversal guard
            if rel_path.startswith("..") or f"{os.sep}..{os.sep}" in rel_path:
                print(f"SKIP: path traversal in rel_path: {rel_path}", file=sys.stderr)
                continue

            # 0a) Symlink guard (Critical fix — не следуем за symlink-файлами)
            if os.path.islink(full_path):
                print(f"SKIP: symlink: {rel_path}", file=sys.stderr)
                continue

            # 1) .agentigore filter
            if is_ignored(rel_path):
                continue

            # 2) Filename PII check (HARD BLOCK) — re.search (не match — basename anywhere)
            for rx in high_filename_re:
                if rx.search(f):
                    print(
                        f"ABORT: filename matches PII pattern: {rel_path}",
                        file=sys.stderr,
                    )
                    return 3

            # 3) Content PII check (HARD BLOCK) — текстовые файлы, до 10MB
            try:
                file_size = os.path.getsize(full_path)
                if file_size > MAX_CONTENT_SCAN:
                    # Файл >10MB и не binary-extension (binaries уже в .agentigore) → reject
                    print(
                        f"ABORT: file >{MAX_CONTENT_SCAN // (1024*1024)}MB unscannable: {rel_path}",
                        file=sys.stderr,
                    )
                    return 3
                with open(full_path, "rb") as fh:
                    content = fh.read(MAX_CONTENT_SCAN)
                for rx in high_content_re:
                    if rx.search(content):
                        print(
                            f"ABORT: content matches PII pattern in {rel_path}",
                            file=sys.stderr,
                        )
                        return 3
                # Medium: IP с пост-фильтром приватных
                for m in ip_pattern.finditer(content):
                    ip = m.group(2)
                    if not private_ip.match(ip):
                        pii_count_medium += 1
            except (OSError, IOError):
                pass  # бинарник / unreadable — filename уже проверен

            # 4) Copy clean file (с safety check: realpath внутри dst)
            dst_path = os.path.join(dst, rel_path)
            if not os.path.realpath(dst_path).startswith(os.path.realpath(dst) + os.sep):
                print(f"SKIP: dst escape attempt: {rel_path}", file=sys.stderr)
                continue
            os.makedirs(os.path.dirname(dst_path), exist_ok=True)
            shutil.copy2(full_path, dst_path)

    if pii_count_medium > 0:
        print(
            f"WARN: {pii_count_medium} non-private IP-addresses found (continuing)",
            file=sys.stderr,
        )

    print(f"INFO: .agentigore filter applied, clean dir = {dst}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
