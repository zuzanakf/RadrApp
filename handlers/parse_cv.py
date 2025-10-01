import base64, json
from typing import Dict, Any
from db import execute, fetchone
from jobs import enqueue_job
from llm.client import chat_json
from llm.prompts import CV_STRUCTURED_PROMPT, TAGS_NORMALIZER_PROMPT
from utils.pdf import pdf_to_text

def upsert_profile(conn, user_id: str, fields: Dict[str, Any]):
    cols = ["user_id"] + list(fields.keys())
    vals = [user_id] + list(fields.values())
    placeholders = ", ".join(["%s"]*len(vals))
    sets = ", ".join([f"{k}=excluded.{k}" for k in fields.keys()])
    sql = f"""
      insert into public.profiles ({", ".join(cols)})
      values ({placeholders})
      on conflict (user_id) do update set {sets}, updated_at=now()
    """
    execute(conn, sql, vals)

def handle(conn, job):
    payload = job["payload_json"]
    user_id = payload["user_id"]
    cv_text = payload.get("cv_text")

    if not cv_text and payload.get("pdf_bytes_base64"):
        cv_text = pdf_to_text(base64.b64decode(payload["pdf_bytes_base64"]))
    if not cv_text:
        raise ValueError("No CV text provided")

    data = chat_json(
        model="gpt-4o-mini",
        system="Return only valid JSON. No commentary.",
        user=CV_STRUCTURED_PROMPT.format(cv_text=cv_text[:100_000])
    )

    norm = chat_json(
        model="gpt-4o-mini",
        system="Return only valid JSON. No commentary.",
        user=TAGS_NORMALIZER_PROMPT.format(input_json=json.dumps({
            "professional_interests": data.get("professional_interests", []),
            "professional_values": data.get("professional_values", []),
            "personal_interests": data.get("personal_interests", []),
            "extracurriculars": data.get("extracurriculars", []),
            "keywords_20": data.get("keywords_20", []),
            "keywords_3": data.get("keywords_3", [])
        }))
    )

    profile_fields = {
        "current_role": data.get("current_role",""),
        "past_experience": data.get("past_experience",""),
        "future_career_aspirations": data.get("future_career_aspirations",""),
        "professional_interests": norm.get("professional_interests", []),
        "professional_values": norm.get("professional_values", []),
        "personal_interests": norm.get("personal_interests", []),
        "extracurriculars": norm.get("extracurriculars", []),
        "tags": norm.get("keywords_3", []),
        "keywords_20": norm.get("keywords_20", []),
        "keywords_3": norm.get("keywords_3", []),
    }
    upsert_profile(conn, user_id, profile_fields)

    # enqueue embeddings
    # enqueue_job(conn, "compute_embeddings", {"user_id": user_id})
    if not payload.get("skip_embeddings", False):
        enqueue_job(conn, "compute_embeddings", {"user_id": user_id})

