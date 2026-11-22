#!/usr/bin/env bash
# routing: server  deterministic=true
# see DP.SC.159, DP.ROLE.059
# server-news.sh — cross-platform replacement WebSearch for server-mode
# see WP-283 (DS-strategy/inbox/WP-283-server-day-open-crossplatform.md)
#
# Outputs a ready markdown-section «World» for DayPlan.
#
# Reads: day-rhythm-config.yaml → news.topics[].feeds (RSS URL-s)
# Parses RSS via curl + python3
# Fallback: if feeds empty or unavailable → explicit PENDING-marker
#
# Usage:
#   bash server-news.sh [CONFIG_PATH]
#   bash server-news.sh ~/IWE/DS-strategy/exocortex/day-rhythm-config.yaml

set -uo pipefail

IWE="${IWE_ROOT:-$HOME/IWE}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
CONFIG="${1:-$IWE/$GOV_REPO/exocortex/day-rhythm-config.yaml}"
MAX_ITEMS_PER_TOPIC=3
MAX_AGE_DAYS=2

# --- Pick a python3 that has PyYAML (shared resolver, WP-529 F6 / #463) ---
# The resolver additionally knows the Homebrew python3 location on stock macOS
# Apple Silicon and fails loud instead of returning a yaml-less interpreter.
RESOLVER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/find-python3.sh"
if ! PYTHON3=$("$RESOLVER"); then
    echo "**World:** ⚠️ PENDING — not found python3 with the library PyYAML. Install: pip3 install pyyaml (or sudo apt install python3-yaml); see. requirements.txt"
    exit 0
fi

$PYTHON3 << PYEOF
import sys, json, subprocess, xml.etree.ElementTree as ET
from datetime import datetime, timezone, timedelta
import yaml

CONFIG = "${CONFIG}"
MAX_ITEMS = ${MAX_ITEMS_PER_TOPIC}
MAX_AGE_DAYS = ${MAX_AGE_DAYS}
CUTOFF = datetime.now(timezone.utc) - timedelta(days=MAX_AGE_DAYS)

# --- Parsing config ---
try:
    with open(CONFIG) as f:
        d = yaml.safe_load(f)
    news_cfg = d.get("news", {})
    if not news_cfg.get("enabled", True):
        sys.exit(0)  # news.enabled=false → section is not rendered, without PENDING
    topics = news_cfg.get("topics", [])
except Exception as e:
    print(f"**World:** ⚠️ PENDING — config error: {e}")
    sys.exit(0)

if not topics:
    print("**World:** ⚠️ PENDING — news.topics not found in config")
    sys.exit(0)

# Collecting all feeds from all topics
all_feeds = []
topic_map = {}  # url → topic_name
for topic in topics:
    topic_name = topic.get("name", "Miscellaneous") if isinstance(topic, dict) else str(topic)
    feeds = topic.get("feeds", []) if isinstance(topic, dict) else []
    for url in feeds:
        if url:
            all_feeds.append(url)
            topic_map[url] = topic_name

if not all_feeds:
    print("**World:** ⚠️ PENDING — RSS feeds not configured. Add to day-rhythm-config.yaml: news.topics[].feeds: [url]")
    sys.exit(0)

# --- Parsing RSS ---
def fetch_rss(url):
    result = subprocess.run(
        ["curl", "-s", "-L", "--max-time", "8", "-A",
         "Mozilla/5.0 (compatible; IWE-newsbot/1.0)",
         url],
        capture_output=True, text=True, timeout=12
    )
    if result.returncode != 0:
        return []
    return parse_rss(result.stdout, url)

def parse_date(date_str):
    """Parsing RFC822 / ISO8601 date from RSS."""
    if not date_str:
        return None
    date_str = date_str.strip()
    # RFC 822 (Fri, 01 May 2026 12:00:00 +0000)
    for fmt in [
        "%a, %d %b %Y %H:%M:%S %z",
        "%a, %d %b %Y %H:%M:%S %Z",
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%dT%H:%M:%SZ",
        "%Y-%m-%d",
    ]:
        try:
            dt = datetime.strptime(date_str, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt
        except ValueError:
            continue
    return None

def parse_rss(xml_text, feed_url):
    items = []
    try:
        root = ET.fromstring(xml_text)
        ns = {}

        # Atom
        atom_ns = "http://www.w3.org/2005/Atom"
        if root.tag == f"{{{atom_ns}}}feed":
            for entry in root.findall(f"{{{atom_ns}}}entry"):
                title_el = entry.find(f"{{{atom_ns}}}title")
                title = title_el.text if title_el is not None else "(no title)"
                link_el = entry.find(f"{{{atom_ns}}}link")
                link = link_el.get("href", "") if link_el is not None else ""
                date_el = entry.find(f"{{{atom_ns}}}updated")
                if date_el is None:
                    date_el = entry.find(f"{{{atom_ns}}}published")
                pub_date = parse_date(date_el.text if date_el is not None else "")
                items.append({"title": title, "link": link, "date": pub_date})
            return items

        # RSS 2.0
        for item in root.iter("item"):
            title_el = item.find("title")
            title = title_el.text if title_el is not None else "(no title)"
            link_el = item.find("link")
            link = (link_el.text or "") if link_el is not None else ""
            date_el = item.find("pubDate")
            if date_el is None:
                date_el = item.find("{http://purl.org/dc/elements/1.1/}date")
            pub_date = parse_date(date_el.text if date_el is not None else "")
            items.append({"title": title, "link": link, "date": pub_date})

    except ET.ParseError:
        pass

    return items

# --- Collecting news ---
results_by_topic = {}
errors = []

for url in all_feeds:
    topic_name = topic_map.get(url, "Miscellaneous")
    try:
        items = fetch_rss(url)
        if not items:
            errors.append(url)
            continue
        # Filtering by date
        recent = []
        for item in items:
            dt = item.get("date")
            if dt is None or dt >= CUTOFF:
                recent.append(item)
        if topic_name not in results_by_topic:
            results_by_topic[topic_name] = []
        results_by_topic[topic_name].extend(recent[:MAX_ITEMS])
    except Exception as e:
        errors.append(f"{url}: {e}")

# --- Rendering section ---
total_items = sum(len(v) for v in results_by_topic.values())

if total_items == 0:
    if errors:
        print("**World:** ⚠️ PENDING — RSS feeds unavailable. Check URLs or add new ones.")
    else:
        print("**World:** no new items in the last 2 days.")
    sys.exit(0)

for topic_name, items in results_by_topic.items():
    if not items:
        continue
    print(f"**{topic_name}:**", end=" ")
    parts = []
    for item in items[:MAX_ITEMS]:
        title = (item.get("title") or "").strip().replace("\n", " ")
        link = (item.get("link") or "").strip()
        dt = item.get("date")
        date_str = f" ({dt.strftime('%d %b')})" if dt else ""
        if link:
            parts.append(f"[{title}]({link}){date_str}")
        else:
            parts.append(f"{title}{date_str}")
    print(". ".join(parts) + ".")

if errors:
    print()
    print(f"> ⚠️ Unavailable feeds: {len(errors)} — check URLs in day-rhythm-config.yaml")
PYEOF
