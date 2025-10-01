from typing import Any, Dict
from db import execute, fetchone

def enqueue_job(conn, job_type: str, payload: Dict[str, Any]):
    sql = "insert into public.jobs (type, payload_json, status) values (%s, %s::jsonb, 'queued')"
    execute(conn, sql, [job_type, json_dump(payload)])

def claim_next_job(conn, max_attempts: int):
    return fetchone(conn, """
        select * from public.jobs
         where status='queued' and attempts < %s
         order by created_at asc
         for update skip locked
         limit 1
    """, [max_attempts])

def mark_running(conn, job_id: int):
    execute(conn, "update public.jobs set status='running', updated_at=now() where id=%s", [job_id])

def mark_done(conn, job_id: int):
    execute(conn, "update public.jobs set status='succeeded', attempts=attempts+1, updated_at=now() where id=%s", [job_id])

def mark_failed(conn, job_id: int, err: str):
    execute(conn, "update public.jobs set status='failed', attempts=attempts+1, last_error=%s, updated_at=now() where id=%s", [err, job_id])

def json_dump(obj):  # small helper here to avoid extra imports
    import json
    return json.dumps(obj, ensure_ascii=False, separators=(",",":"))
