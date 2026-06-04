#!/usr/bin/env bash
# routing: server  deterministic=true
# see DP.SC.159, DP.ROLE.059
# server-news.sh — кросс-платформенная замена WebSearch для server-mode
# see WP-283 (DS-strategy/inbox/WP-283-server-day-open-crossplatform.md)
#
# Выводит готовую markdown-секцию «Мир» для DayPlan.
#
# Читает: day-rhythm-config.yaml → news.topics[].feeds (RSS URL-ы)
# Парсит RSS через curl + python3
# Fallback: если feeds пусты или недоступны → явный PENDING-маркер
#
# Использование:
#   bash server-news.sh [CONFIG_PATH]
#   bash server-news.sh ~/IWE/DS-strategy/exocortex/day-rhythm-config.yaml

set -uo pipefail

IWE="${IWE_ROOT:-$HOME/IWE}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
CONFIG="${1:-$IWE/$GOV_REPO/exocortex/day-rhythm-config.yaml}"
MAX_ITEMS_PER_TOPIC=3
MAX_AGE_DAYS=2

# --- Выбираем python3 с PyYAML (NixOS: scheduler env имеет yaml, base не имеет) ---
_find_python3() {
  if python3 -c "import yaml" 2>/dev/null; then echo "python3"; return; fi
  local p
  for p in \
    /nix/store/aj1smkrsnv16lbz9g8qancb04b3kv0va-python3-3.12.8-env/bin/python3 \
    /usr/bin/python3 /usr/local/bin/python3; do
    [[ -x "$p" ]] && "$p" -c "import yaml" 2>/dev/null && { echo "$p"; return; }
  done
  find /nix/store -maxdepth 3 -name "python3" -path "*env*/bin/*" 2>/dev/null | while read -r p; do
    "$p" -c "import yaml" 2>/dev/null && { echo "$p"; return; }
  done
  echo "python3"
}
PYTHON3=$(_find_python3)

$PYTHON3 << PYEOF
import sys, json, subprocess, xml.etree.ElementTree as ET
from datetime import datetime, timezone, timedelta
import yaml

CONFIG = "${CONFIG}"
MAX_ITEMS = ${MAX_ITEMS_PER_TOPIC}
MAX_AGE_DAYS = ${MAX_AGE_DAYS}
CUTOFF = datetime.now(timezone.utc) - timedelta(days=MAX_AGE_DAYS)

# --- Парсим конфиг ---
try:
    with open(CONFIG) as f:
        d = yaml.safe_load(f)
    news_cfg = d.get("news", {})
    if not news_cfg.get("enabled", True):
        sys.exit(0)  # news.enabled=false → секция не рендерится, без PENDING
    topics = news_cfg.get("topics", [])
except Exception as e:
    print(f"**Мир:** ⚠️ PENDING — ошибка конфига: {e}")
    sys.exit(0)

if not topics:
    print("**Мир:** ⚠️ PENDING — news.topics не найдены в конфиге")
    sys.exit(0)

# Собираем все feeds со всех топиков
all_feeds = []
topic_map = {}  # url → topic_name
for topic in topics:
    topic_name = topic.get("name", "Разное") if isinstance(topic, dict) else str(topic)
    feeds = topic.get("feeds", []) if isinstance(topic, dict) else []
    for url in feeds:
        if url:
            all_feeds.append(url)
            topic_map[url] = topic_name

if not all_feeds:
    print("**Мир:** ⚠️ PENDING — RSS feeds не настроены. Добавить в day-rhythm-config.yaml: news.topics[].feeds: [url]")
    sys.exit(0)

# --- Парсим RSS ---
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
    """Парсим RFC822 / ISO8601 дату из RSS."""
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
                title = title_el.text if title_el is not None else "(без заголовка)"
                link_el = entry.find(f"{{{atom_ns}}}link")
                link = link_el.get("href", "") if link_el is not None else ""
                date_el = entry.find(f"{{{atom_ns}}}updated") or entry.find(f"{{{atom_ns}}}published")
                pub_date = parse_date(date_el.text if date_el is not None else "")
                items.append({"title": title, "link": link, "date": pub_date})
            return items

        # RSS 2.0
        for item in root.iter("item"):
            title_el = item.find("title")
            title = title_el.text if title_el is not None else "(без заголовка)"
            link_el = item.find("link")
            link = (link_el.text or "") if link_el is not None else ""
            date_el = item.find("pubDate") or item.find("{http://purl.org/dc/elements/1.1/}date")
            pub_date = parse_date(date_el.text if date_el is not None else "")
            items.append({"title": title, "link": link, "date": pub_date})

    except ET.ParseError:
        pass

    return items

# --- Собираем новости ---
results_by_topic = {}
errors = []

for url in all_feeds:
    topic_name = topic_map.get(url, "Разное")
    try:
        items = fetch_rss(url)
        if not items:
            errors.append(url)
            continue
        # Фильтруем по дате
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

# --- Выводим секцию ---
total_items = sum(len(v) for v in results_by_topic.values())

if total_items == 0:
    if errors:
        print("**Мир:** ⚠️ PENDING — RSS feeds недоступны. Проверить URLs или добавить новые.")
    else:
        print("**Мир:** нет новых материалов за последние 2 дня.")
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
    print(f"> ⚠️ Недоступных feeds: {len(errors)} — проверить URLs в day-rhythm-config.yaml")
PYEOF
