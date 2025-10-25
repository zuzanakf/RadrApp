import time, traceback
from config import POLL_INTERVAL, MAX_ATTEMPTS, WORKER_NAME
from db import connect
from jobs import claim_next_job, mark_running, mark_done, mark_failed

# Import handlers
#from handlers import parse_cv, compute_embeddings, three_things
from handlers import build_radr_embeddings, compute_embeddings, parse_cv

HANDLERS = {
    "parse_cv": parse_cv.handle,
    "parse_cv_from_storage": parse_cv.handle,
    "compute_embeddings": compute_embeddings.handle,
    "build_radr_embeddings": build_radr_embeddings.handle,
    # "gen_three_things": three_things.handle,
}

if __name__ == "__main__":
    print(f"[{WORKER_NAME}] starting poller ...")
    while True:
        job = None
        try:
            with connect(autocommit=False) as conn:
                with conn.transaction():
                    job = claim_next_job(conn, MAX_ATTEMPTS)
                    if job:
                        mark_running(conn, job["id"])

                if not job:
                    time.sleep(POLL_INTERVAL)
                    continue

                conn.commit()

            # run outside txn
            handler = HANDLERS.get(job["type"])
            if not handler:
                raise ValueError(f"Unknown job type: {job['type']}")

            with connect(autocommit=True) as run_conn:
                handler(run_conn, job)

            with connect(autocommit=False) as done_conn:
                with done_conn.transaction():
                    mark_done(done_conn, job["id"])
                done_conn.commit()

        except Exception as e:
            print(f"[{WORKER_NAME}] error: {e}")
            traceback.print_exc()
            # best-effort failure update
            try:
                with connect(autocommit=False) as fail_conn:
                    with fail_conn.transaction():
                        if job:
                            mark_failed(fail_conn, job["id"], f"{type(e).__name__}: {e}")
                    fail_conn.commit()
            except Exception:
                pass
            time.sleep(POLL_INTERVAL)
