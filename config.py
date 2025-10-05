import os
from dotenv import load_dotenv

load_dotenv()  # local only; Railway injects env vars directly

DB_URL = os.getenv("SUPABASE_DB_URL")
SUPABASE_URL = os.getenv("SUPABASE_URL")  # optional
SUPABASE_SERVICE_ROLE_KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY")  # optional (storage)

OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
EMBEDDING_PROVIDER = os.getenv("EMBEDDING_PROVIDER", "openai")
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "text-embedding-3-small")

_embedding_dims_env = os.getenv("EMBEDDING_DIMS")
if _embedding_dims_env and _embedding_dims_env.lower() not in {"auto", "infer"}:
    EMBEDDING_DIMS = int(_embedding_dims_env)
else:
    EMBEDDING_DIMS = None

POLL_INTERVAL = float(os.getenv("POLL_INTERVAL_SECONDS", "2"))
MAX_ATTEMPTS = int(os.getenv("MAX_ATTEMPTS", "3"))
WORKER_NAME = os.getenv("WORKER_NAME", "radr-worker")

assert DB_URL, "SUPABASE_DB_URL env var required"
assert OPENAI_API_KEY, "OPENAI_API_KEY required"
