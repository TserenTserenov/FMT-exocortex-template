#!/usr/bin/env python3
"""
dt-collect-neon.py — запись собранных данных активности в digital_twins (Neon).

Паттерн: deep merge JSONB (как sync_engagement_to_dt в боте).
Пишет 2_collected.2_6_coding и 2_collected.2_7_iwe.

Использование:
    python3 dt-collect-neon.py <user_id> '<json_data>'

Требует:
    NEON_URL — connection string (из env)
    pip: psycopg2-binary (sync, не asyncpg — скрипт одноразовый)
"""

import json
import os
import sys
from datetime import datetime, timezone


def main():
    if len(sys.argv) < 3:
        print("Usage: dt-collect-neon.py <user_id> '<json_data>'", file=sys.stderr)
        sys.exit(1)

    user_id = sys.argv[1]
    collected_data = json.loads(sys.argv[2])

    neon_url = os.environ.get("NEON_URL")
    if not neon_url:
        print("NEON_URL not set", file=sys.stderr)
        sys.exit(1)

    try:
        import psycopg2
        import psycopg2.extras
    except ImportError:
        # Fallback: try asyncpg via asyncio
        print("psycopg2 not found, trying asyncpg...", file=sys.stderr)
        _write_asyncpg(neon_url, user_id, collected_data)
        return

    _write_psycopg2(neon_url, user_id, collected_data)


def _write_psycopg2(neon_url, user_id, collected_data):
    import psycopg2
    import psycopg2.extras

    conn = psycopg2.connect(neon_url)
    try:
        with conn.cursor() as cur:
            # Ensure table exists
            cur.execute("""
                CREATE TABLE IF NOT EXISTS digital_twins (
                    user_id TEXT PRIMARY KEY,
                    data JSONB NOT NULL DEFAULT '{}',
                    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
            """)

            # Deep merge: preserve existing data, update 2_collected groups
            cur.execute("""
                INSERT INTO digital_twins (user_id, data, created_at, updated_at)
                VALUES (%s, jsonb_build_object('2_collected', %s::jsonb), NOW(), NOW())
                ON CONFLICT (user_id) DO UPDATE SET
                    data = COALESCE(digital_twins.data, '{}'::jsonb)
                        || jsonb_build_object('2_collected',
                            COALESCE(digital_twins.data->'2_collected', '{}'::jsonb)
                            || %s::jsonb
                        ),
                    updated_at = NOW()
            """, (user_id, json.dumps(collected_data), json.dumps(collected_data)))

            conn.commit()
            print(f"OK: written for user {user_id}")
    finally:
        conn.close()


def _write_asyncpg(neon_url, user_id, collected_data):
    import asyncio
    import asyncpg

    async def write():
        conn = await asyncpg.connect(neon_url)
        try:
            await conn.execute("""
                CREATE TABLE IF NOT EXISTS digital_twins (
                    user_id TEXT PRIMARY KEY,
                    data JSONB NOT NULL DEFAULT '{}',
                    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
            """)

            await conn.execute("""
                INSERT INTO digital_twins (user_id, data, created_at, updated_at)
                VALUES ($1, jsonb_build_object('2_collected', $2::jsonb), NOW(), NOW())
                ON CONFLICT (user_id) DO UPDATE SET
                    data = COALESCE(digital_twins.data, '{}'::jsonb)
                        || jsonb_build_object('2_collected',
                            COALESCE(digital_twins.data->'2_collected', '{}'::jsonb)
                            || $2::jsonb
                        ),
                    updated_at = NOW()
            """, user_id, json.dumps(collected_data))

            print(f"OK: written for user {user_id}")
        finally:
            await conn.close()

    asyncio.run(write())


if __name__ == "__main__":
    main()
