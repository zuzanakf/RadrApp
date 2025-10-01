from typing import Any, List, Optional
from urllib.parse import urlparse

import psycopg
from psycopg.rows import dict_row

from config import DB_URL


def connect(autocommit: bool = False):
    try:
        return psycopg.connect(DB_URL, autocommit=autocommit)
    except psycopg.OperationalError as exc:
        message = str(exc)
        if "nodename nor servname provided" in message:
            parsed = urlparse(DB_URL or "")
            host_hint = parsed.hostname or "(host missing)"
            raise RuntimeError(
                "Could not resolve the database host from SUPABASE_DB_URL. "
                "Make sure you copied the PostgreSQL connection string from "
                "Supabase (Project Settings → Database → Connection string) "
                "and that it includes the correct host (for example, "
                "'db.<project>.supabase.co'). Current host value: "
                f"{host_hint}. Original error: {message}"
            ) from exc
        raise


def fetchone(conn, sql: str, params: Optional[List[Any]] = None):
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute(sql, params or [])
        return cur.fetchone()


def fetchall(conn, sql: str, params: Optional[List[Any]] = None):
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute(sql, params or [])
        return cur.fetchall()


def execute(conn, sql: str, params: Optional[List[Any]] = None):
    with conn.cursor() as cur:
        cur.execute(sql, params or [])
