"""
L3 AI Quality Evaluation -- LLM-as-Judge runner.

Выбирает реальные диалоги из PostgreSQL,
оценивает по rubrics из rubrics.yaml через Claude Haiku,
генерирует weekly report.

Адаптировать:
    - fetch_samples_from_db(): SQL-запрос под свою схему
    - JUDGE_MODEL: модель судьи
    - rubrics.yaml: criteria под свой бот

Использование:
    python eval_runner.py --period 7 --sample 50 --output report.md
"""

import argparse
import asyncio
import json
import logging
import os
import sys
from datetime import datetime
from pathlib import Path

import yaml

logger = logging.getLogger(__name__)

JUDGE_MODEL = "claude-haiku-4-5-20251001"

JUDGE_SYSTEM_PROMPT = """\
You are an AI quality evaluator. You assess chatbot responses against specific criteria.

For each metric, output a JSON object with exactly these fields:
- "score": float 0.0-1.0
- "passed": boolean (score >= threshold)
- "reasoning": 1-2 sentence explanation in Russian

Be strict but fair."""


def load_rubrics() -> dict:
    rubrics_path = Path(__file__).parent / "rubrics.yaml"
    with open(rubrics_path, encoding="utf-8") as f:
        return yaml.safe_load(f)


async def fetch_samples_from_db(period_days: int, sample_size: int) -> list:
    """Fetch dialogues from DB. Adapt SQL to your schema."""
    database_url = os.getenv("DATABASE_URL")
    if not database_url:
        print("DATABASE_URL not set. Skipping.")
        return []

    try:
        import asyncpg
        pool = await asyncpg.create_pool(database_url, min_size=1, max_size=3)
        async with pool.acquire() as conn:
            # TODO: adapt to your table/column names
            rows = await conn.fetch("""
                SELECT id, question, answer, helpful, created_at
                FROM qa_history
                WHERE created_at >= NOW() - INTERVAL '{} days'
                ORDER BY RANDOM()
                LIMIT $1
            """.format(period_days), sample_size)
            samples = [dict(row) for row in rows]
        await asyncio.wait_for(pool.close(), timeout=10)
        return samples
    except Exception as e:
        print(f"DB sampling error: {e}")
        return []


async def evaluate_sample(sample: dict, rubrics: dict, client) -> dict:
    """Evaluate one dialogue against all rubrics via LLM-as-Judge."""
    question = sample.get("question", "")
    answer = sample.get("answer", "")

    results = {}
    for metric in rubrics["metrics"]:
        name = metric["name"]
        threshold = metric["threshold"]
        criteria = metric["criteria"]

        user_prompt = f"""Evaluate this response against the metric "{name}".

**Criteria:**
{criteria}

**Threshold:** {threshold}

**User input:** {question}
**Agent response:** {answer}

Return ONLY a valid JSON object:
{{"score": <float 0.0-1.0>, "passed": <bool>, "reasoning": "<1-2 sentences in Russian>"}}"""

        try:
            response = await client.messages.create(
                model=JUDGE_MODEL,
                max_tokens=200,
                system=JUDGE_SYSTEM_PROMPT,
                messages=[{"role": "user", "content": user_prompt}],
            )
            raw = response.content[0].text.strip()
            if raw.startswith("```"):
                raw = raw.split("\n", 1)[1].rsplit("```", 1)[0].strip()
            try:
                parsed = json.loads(raw)
            except json.JSONDecodeError:
                import re
                score_match = re.search(r'"score"\s*:\s*([\d.]+)', raw)
                if score_match:
                    score_val = float(score_match.group(1))
                    parsed = {"score": score_val, "passed": score_val >= threshold,
                              "reasoning": "JSON truncated"}
                else:
                    raise
            results[name] = {
                "score": float(parsed["score"]),
                "threshold": threshold,
                "passed": parsed.get("passed", float(parsed["score"]) >= threshold),
                "reasoning": parsed.get("reasoning", ""),
            }
        except Exception as e:
            logger.warning(f"Judge failed for {name}: {e}")
            results[name] = {
                "score": None, "threshold": threshold,
                "passed": None, "reasoning": f"Error: {e}",
            }

    return results


def generate_report(evaluations: list, rubrics: dict, period_days: int) -> str:
    today = datetime.now().strftime("%Y-%m-%d")
    report = f"# L3 AI Quality Report -- {today}\n\n"
    report += "| Metric | Threshold | Avg | Passed | Status |\n"
    report += "|--------|:---------:|:---:|:------:|:------:|\n"

    for metric in rubrics["metrics"]:
        name = metric["name"]
        threshold = metric["threshold"]
        scores = [e["results"].get(name, {}).get("score") for e in evaluations
                  if e["results"].get(name, {}).get("score") is not None]
        passed_count = sum(1 for e in evaluations
                          if e["results"].get(name, {}).get("passed") is True)
        total = len(scores)
        if scores:
            avg = sum(scores) / len(scores)
            status = "PASS" if avg >= threshold else "**FAIL**"
        else:
            avg = 0
            status = "NO DATA"
            total = 0
        report += f"| {name} | {threshold} | {avg:.2f} | {passed_count}/{total} | {status} |\n"

    report += f"\n- Period: {period_days} days, Sample: {len(evaluations)}, Judge: {JUDGE_MODEL}\n"
    return report


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--period", type=int, default=7)
    parser.add_argument("--sample", type=int, default=50)
    parser.add_argument("--output", type=str, default=None)
    args = parser.parse_args()

    rubrics = load_rubrics()
    print(f"Loaded {len(rubrics['metrics'])} metrics")

    samples = await fetch_samples_from_db(args.period, args.sample)
    print(f"Fetched {len(samples)} samples")

    if not samples:
        report = generate_report([], rubrics, args.period)
    else:
        import anthropic
        client = anthropic.AsyncAnthropic()
        evaluations = []
        for i, sample in enumerate(samples):
            results = await evaluate_sample(sample, rubrics, client)
            evaluations.append({"sample": sample, "results": results})
            if (i + 1) % 10 == 0:
                print(f"  Evaluated {i + 1}/{len(samples)}")
        report = generate_report(evaluations, rubrics, args.period)

    output_path = args.output or f"deepeval-{datetime.now().strftime('%Y-%m-%d')}.md"
    Path(output_path).write_text(report)
    print(f"Report: {output_path}")


if __name__ == "__main__":
    asyncio.run(main())
