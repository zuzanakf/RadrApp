from typing import Any, Dict, List, Optional
import psycopg
from psycopg.rows import dict_row
from config import DB_URL

def connect(autocommit: bool = False):
    return psycopg.connect(DB_URL, autocommit=autocommit)

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
