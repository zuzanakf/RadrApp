# Radr Background Worker

RadrApp is a lightweight Python worker that powers asynchronous processing for the Radr platform. It watches the `public.jobs` table in Supabase, claims new work items, and dispatches them to dedicated job handlers. Current handlers parse CV documents and enrich the resulting profiles with vector embeddings.

## FrontEnd Demo
<img width="2556" height="1436" alt="image" src="https://github.com/user-attachments/assets/3bdcda3a-4a4f-4e9b-ad33-9c6f0b219df1" />
<img width="2556" height="1430" alt="image" src="https://github.com/user-attachments/assets/f3786406-8d17-4e80-9268-9cb495cd0b5c" />

## Architecture Overview

The worker follows a simple polling loop implemented in [`app.py`](app.py):

1. Poll the database for queued jobs using the connection helpers in [`db.py`](db.py).
2. Claim the oldest job that has not exceeded the retry limit defined in [`config.py`](config.py).
3. Look up the handler function for the job's `type` in the [`HANDLERS` registry](app.py#L11-L18).
4. Execute the handler, allowing it to read or write additional data.
5. Mark the job as succeeded or failed and sleep for a short interval before the next poll.

Handlers live in the [`handlers/`](handlers) package and must expose a `handle(conn, job)` function. Example handlers:

- [`handlers/parse_cv.py`](handlers/parse_cv.py) extracts structured data from a CV (PDF or text) using OpenAI, normalizes tags, writes the profile to Supabase, and enqueues a follow-up embedding job.
- [`handlers/compute_embeddings.py`](handlers/compute_embeddings.py) fetches the profile, generates embeddings with the configured OpenAI model, and persists the vectors back to Supabase.

Supporting modules include:

- [`jobs.py`](jobs.py): helper utilities to enqueue, claim, and update job records.
- [`llm/`](llm): thin wrappers around the OpenAI SDK and reusable prompt templates.
- [`utils/`](utils): helper functions (e.g., PDF parsing) used across handlers.

## Prerequisites

- Python 3.11+
- A PostgreSQL-compatible Supabase instance with the `public.jobs`, `public.profiles`, and `public.user_embeddings` tables.
- An OpenAI API key with access to the models referenced in [`config.py`](config.py).

## Environment Variables

Create a `.env` file in the project root or export the variables directly in your shell. Required keys:

| Variable | Description |
| --- | --- |
| `SUPABASE_DB_URL` | Supabase PostgreSQL connection string. |
| `OPENAI_API_KEY` | API key for the OpenAI Responses and Embeddings APIs. |

Optional overrides:

| Variable | Description |
| --- | --- |
| `SUPABASE_URL` | Base URL for Supabase Storage (needed when downloading CVs). |
| `SUPABASE_SERVICE_ROLE_KEY` | Service role key required to access Supabase Storage. |
| `EMBEDDING_PROVIDER` | Embedding provider name (defaults to `openai`). |
| `EMBEDDING_MODEL` | Embedding model identifier. |
| `EMBEDDING_DIMS` | Target embedding dimensionality. |
| `POLL_INTERVAL_SECONDS` | Delay between polling iterations. |
| `MAX_ATTEMPTS` | Maximum retry attempts before jobs stop being retried. |
| `WORKER_NAME` | Name displayed in worker log output. |

## Local Development

### 1. Create and Activate a Virtual Environment

```bash
python3 -m venv .venv
source .venv/bin/activate  # On Windows use: .venv\\Scripts\\activate
```

### 2. Install Dependencies

```bash
pip install --upgrade pip
pip install -r requirements.txt
```

### 3. Configure Environment Variables

```bash
cp .env.example .env  # optional helper if you maintain an example file
# edit .env and fill in SUPABASE_DB_URL, OPENAI_API_KEY, etc.
```

### 4. Run the Worker Locally

```bash
python app.py
```

The worker will log when it starts polling and each time it claims, succeeds, or fails a job.

## Adding a New Job Handler

Follow these steps to introduce a new job type:

1. **Create the handler module** in `handlers/`. Export a `handle(conn, job)` function that accepts an open database connection and the full job record (as a dict). Use the helpers in [`db.py`](db.py) and [`jobs.py`](jobs.py) as needed.

    ```python
    # handlers/my_new_job.py
    from db import fetchone, execute

    def handle(conn, job):
        payload = job["payload_json"]
        # ...perform work...
        execute(conn, "update ...", [...])
    ```

2. **Register the handler** in [`app.py`](app.py) by importing the module and adding it to the `HANDLERS` dictionary.

    ```python
    from handlers import my_new_job

    HANDLERS = {
        "my_new_job": my_new_job.handle,
        # ...
    }
    ```

3. **Enqueue jobs** with the new `type` using `jobs.enqueue_job` or by inserting rows directly into `public.jobs`. Ensure the payload JSON includes all fields your handler expects.

4. **Test locally** by running `python app.py` and confirming the worker logs show your job being processed.

## Troubleshooting

- *Database host errors:* Make sure the `SUPABASE_DB_URL` uses the full host name (e.g., `db.<project>.supabase.co`). The helper in [`db.py`](db.py) emits a descriptive error when DNS resolution fails.
- *Missing storage credentials:* `handlers/parse_cv.py` requires `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` when downloading files from Supabase Storage.
- *Embedding size mismatch:* If you override `EMBEDDING_DIMS`, ensure the target dimension is not larger than the returned embedding length.

## License

This repository is proprietary to Radr. Contact the maintainers for usage permissions.
