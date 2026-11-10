#!/usr/bin/env python3
"""
Генерация обложки для поста через OpenAI GPT Image 1 API.

Использование:
  # Сгенерировать картинку для поста (промпт из содержимого):
  python generate_post_image.py path/to/post.md

  # С кастомным промптом:
  python generate_post_image.py path/to/post.md --prompt "мост между двумя мирами знаний"

  # Указать размер (по умолчанию 1536x1024 — горизонтальная обложка):
  python generate_post_image.py path/to/post.md --size 1024x1024

  # Указать качество (low / medium / high):
  python generate_post_image.py path/to/post.md --quality high

  # Dry-run (показать промпт, не генерировать):
  python generate_post_image.py path/to/post.md --dry-run

Конфигурация:
  API key: ~/IWE/.secrets/openai-api-key или OPENAI_API_KEY env var

Результат сохраняется рядом с постом: cover.png
"""

from __future__ import annotations

import argparse
import base64
import logging
import os
import re
import sys
from pathlib import Path

import httpx
import yaml

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("image-gen")

# ─── Константы ────────────────────────────────────────────────────────────

# Ищем API key: .secrets/ в workspace → env var
_WORKSPACE = Path(__file__).resolve().parent.parent.parent  # setup/optional/ → workspace root
SECRETS_PATH = _WORKSPACE / ".secrets" / "openai-api-key"
API_URL = "https://api.openai.com/v1/images/generations"
MODEL = "gpt-image-2.6-sunburst"
FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n(.*)", re.DOTALL)


# ─── Загрузка API key ────────────────────────────────────────────────────

def load_api_key() -> str:
    """Загрузить OpenAI API key из файла или env."""
    key = os.environ.get("OPENAI_API_KEY")
    if key:
        return key.strip()
    if SECRETS_PATH.exists():
        return SECRETS_PATH.read_text().strip()
    log.error("API key не найден. Положите ключ в %s или задайте OPENAI_API_KEY", SECRETS_PATH)
    sys.exit(1)


# ─── Парсинг поста ────────────────────────────────────────────────────────

def parse_post(path: Path) -> tuple[dict, str]:
    """Извлечь frontmatter и тело поста."""
    text = path.read_text(encoding="utf-8")
    m = FRONTMATTER_RE.match(text)
    if not m:
        log.error("Нет frontmatter в %s", path)
        sys.exit(1)
    meta = yaml.safe_load(m.group(1)) or {}
    body = m.group(2).strip()
    return meta, body


def extract_content(meta: dict, body: str) -> dict:
    """Извлечь структурированное содержание поста для промпта."""
    title = meta.get("title", "")
    tags = [str(t) for t in meta.get("tags", [])]
    audience = meta.get("audience", "community")

    # Собираем абзацы (без заголовков, таблиц, кодовых блоков)
    paragraphs = []
    for line in body.split("\n\n"):
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("|") or line.startswith("```"):
            continue
        # Убираем markdown-форматирование для чистого текста
        clean = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", line)  # ссылки → текст
        clean = re.sub(r"\*\*(.+?)\*\*", r"\1", clean)  # bold
        clean = re.sub(r"\*(.+?)\*", r"\1", clean)  # italic
        paragraphs.append(clean)
        if len(paragraphs) >= 8:
            break

    full_text = " ".join(paragraphs)[:2000]

    # Определяем настроение по аудитории
    mood_map = {
        "wide": "warm, inviting, hopeful — like a sunrise over a new path",
        "community": "focused, collaborative, practical — like a workshop with tools laid out",
        "advanced": "precise, technical, deep — like a blueprint under focused light",
    }
    mood = mood_map.get(audience, mood_map["community"])

    return {
        "title": title,
        "tags": tags,
        "text": full_text,
        "mood": mood,
        "audience": audience,
    }


def build_prompt(meta: dict, body: str, custom_prompt: str | None = None) -> str:
    """Построить SOTA-промпт для GPT Image из содержимого поста."""
    if custom_prompt:
        return (
            f"A wide cinematic digital illustration for a blog article. "
            f"The scene visually represents: {custom_prompt}. "
            f"Style: conceptual editorial art, rich color palette, volumetric lighting. "
            f"No text, no letters, no words, no labels, no watermarks. "
            f"The image should immediately communicate the core idea."
        )

    content = extract_content(meta, body)

    prompt = (
        f"Create a wide cinematic editorial illustration for a blog article "
        f"titled \"{content['title']}\".\n\n"
        f"ARTICLE CONTENT (use this to understand the topic and find the right visual metaphor):\n"
        f"{content['text']}\n\n"
        f"VISUAL DIRECTION:\n"
        f"- Find the single most powerful VISUAL METAPHOR from the article content above\n"
        f"- The image must tell the story of the article without any words\n"
        f"- Mood: {content['mood']}\n"
        f"- Style: conceptual editorial art, like a high-end magazine cover illustration\n"
        f"- Composition: wide cinematic shot, rule of thirds, depth of field\n"
        f"- Lighting: volumetric, atmospheric, cinematic\n"
        f"- Color palette: rich and purposeful, matching the mood\n\n"
        f"STRICT RULES:\n"
        f"- NO text, letters, words, labels, or watermarks anywhere in the image\n"
        f"- NO generic stock-photo compositions\n"
        f"- The image must be UNIQUE and specific to THIS article's topic\n"
        f"- Prefer symbolic/metaphorical representation over literal depiction"
    )

    if content["tags"]:
        prompt += f"\n\nKey themes: {', '.join(content['tags'][:5])}"

    # GPT Image prompt limit: ~32K chars (much more generous than DALL-E 3)
    return prompt[:4000]


# ─── Генерация ────────────────────────────────────────────────────────────

def generate_image(
    api_key: str,
    prompt: str,
    size: str = "1536x1024",
    quality: str = "medium",
) -> bytes:
    """Вызвать GPT Image API и вернуть PNG bytes."""
    log.info("Генерирую картинку (%s, quality=%s, model=%s)...", size, quality, MODEL)
    log.info("Промпт: %s", prompt[:300] + "..." if len(prompt) > 300 else prompt)

    with httpx.Client(timeout=180) as client:
        resp = client.post(
            API_URL,
            headers={"Authorization": f"Bearer {api_key}"},
            json={
                "model": MODEL,
                "prompt": prompt,
                "n": 1,
                "size": size,
                "quality": quality,
            },
        )

    if resp.status_code != 200:
        log.error("API ошибка %d: %s", resp.status_code, resp.text[:500])
        sys.exit(1)

    data = resp.json()
    b64 = data["data"][0].get("b64_json")
    if b64:
        return base64.b64decode(b64)

    # Fallback: URL-based response
    url = data["data"][0].get("url")
    if url:
        log.info("Скачиваю по URL...")
        with httpx.Client(timeout=60) as dl_client:
            dl_resp = dl_client.get(url)
            if dl_resp.status_code == 200:
                return dl_resp.content
        log.error("Не удалось скачать по URL")

    log.error("Нет данных в ответе: %s", str(data)[:500])
    sys.exit(1)


# ─── Определение пути сохранения ──────────────────────────────────────────

def output_path(post_path: Path) -> Path:
    """Определить путь для сохранения картинки рядом с постом."""
    # Если пост в директории (multi-channel) — сохраняем в директорию
    if post_path.parent.name != post_path.stem:
        return post_path.parent / "cover.png"
    else:
        stem = post_path.stem
        return post_path.parent / f"{stem}-cover.png"


# ─── CLI ──────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Генерация обложки для поста (GPT Image)")
    parser.add_argument("post", type=Path, help="Путь к .md файлу поста")
    parser.add_argument("--prompt", type=str, default=None, help="Кастомный промпт (вместо автоматического)")
    parser.add_argument("--size", type=str, default="1536x1024",
                        choices=["1024x1024", "1536x1024", "1024x1536"],
                        help="Размер картинки (по умолчанию 1536x1024)")
    parser.add_argument("--quality", type=str, default="medium",
                        choices=["low", "medium", "high"],
                        help="Качество (по умолчанию medium)")
    parser.add_argument("--dry-run", action="store_true", help="Показать промпт без генерации")
    parser.add_argument("--output", "-o", type=Path, default=None, help="Путь сохранения (по умолчанию рядом с постом)")
    args = parser.parse_args()

    if not args.post.exists():
        log.error("Файл не найден: %s", args.post)
        sys.exit(1)

    meta, body = parse_post(args.post)
    prompt = build_prompt(meta, body, args.prompt)

    if args.dry_run:
        print(f"Модель: {MODEL}")
        print(f"Промпт ({len(prompt)} символов):\n")
        print(prompt)
        print(f"\nСохранение: {args.output or output_path(args.post)}")
        return

    api_key = load_api_key()
    image_bytes = generate_image(api_key, prompt, args.size, args.quality)

    out = args.output or output_path(args.post)
    out.write_bytes(image_bytes)
    log.info("Сохранено: %s (%d KB)", out, len(image_bytes) // 1024)
    print(f"\n✅ {out}")


if __name__ == "__main__":
    main()
