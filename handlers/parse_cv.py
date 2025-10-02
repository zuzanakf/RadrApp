import base64
import binascii
import json
from typing import Any, Dict
from urllib.parse import quote
from urllib.request import Request, urlopen

from pydantic import BaseModel, Field

from config import SUPABASE_SERVICE_ROLE_KEY, SUPABASE_URL
from db import execute
from jobs import enqueue_job
from llm.client import parse_structured_response
from llm.prompts import CV_STRUCTURED_PROMPT, TAGS_NORMALIZER_PROMPT
from utils.pdf import pdf_to_text


class CVStructuredData(BaseModel):
    current_role_title: str = ""
    past_experience: str = ""
    future_career_aspirations: str = ""
    professional_interests: list[str] = Field(default_factory=list)
    professional_values: list[str] = Field(default_factory=list)
    personal_interests: list[str] = Field(default_factory=list)
    extracurriculars: list[str] = Field(default_factory=list)
    keywords_20: list[str] = Field(default_factory=list)
    keywords_3: list[str] = Field(default_factory=list)


class NormalizedTags(BaseModel):
    professional_interests: list[str] = Field(default_factory=list)
    professional_values: list[str] = Field(default_factory=list)
    personal_interests: list[str] = Field(default_factory=list)
    extracurriculars: list[str] = Field(default_factory=list)
    keywords_20: list[str] = Field(default_factory=list)
    keywords_3: list[str] = Field(default_factory=list)


def upsert_profile(conn, user_id: str, fields: Dict[str, Any]):
    cols = ["user_id"] + list(fields.keys())
    vals = [user_id] + list(fields.values())
    placeholders = ", ".join(["%s"] * len(vals))
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

    if job["type"] == "parse_cv_from_storage":
        pdf_bytes = _load_pdf_from_storage_payload(payload)
        cv_text = pdf_to_text(pdf_bytes)
    elif not cv_text and payload.get("pdf_bytes_base64"):
        cv_text = pdf_to_text(base64.b64decode(payload["pdf_bytes_base64"]))
    if not cv_text:
        raise ValueError("No CV text provided")

    cv_data = parse_structured_response(
        model="gpt-4o-mini",
        messages=[
            {"role": "system", "content": "Extract the CV information as structured data."},
            {
                "role": "user",
                "content": CV_STRUCTURED_PROMPT.format(cv_text=cv_text[:100_000]),
            },
        ],
        schema=CVStructuredData,
    )

    normalization_payload = json.dumps(
        {
            "professional_interests": cv_data.professional_interests,
            "professional_values": cv_data.professional_values,
            "personal_interests": cv_data.personal_interests,
            "extracurriculars": cv_data.extracurriculars,
            "keywords_20": cv_data.keywords_20,
            "keywords_3": cv_data.keywords_3,
        }
    )

    normalized = parse_structured_response(
        model="gpt-4o-mini",
        messages=[
            {"role": "system", "content": "Canonicalize and return structured JSON."},
            {
                "role": "user",
                "content": TAGS_NORMALIZER_PROMPT.format(input_json=normalization_payload),
            },
        ],
        schema=NormalizedTags,
    )

    profile_fields = {
        "current_role_title": cv_data.current_role_title,
        "past_experience": cv_data.past_experience,
        "future_career_aspirations": cv_data.future_career_aspirations,
        "professional_interests": normalized.professional_interests,
        "professional_values": normalized.professional_values,
        "personal_interests": normalized.personal_interests,
        "extracurriculars": normalized.extracurriculars,
        "tags": normalized.keywords_3,
        "keywords_20": normalized.keywords_20,
        "keywords_3": normalized.keywords_3,
    }
    upsert_profile(conn, user_id, profile_fields)

    if not payload.get("skip_embeddings", False):
        enqueue_job(conn, "compute_embeddings", {"user_id": user_id})


def _load_pdf_from_storage_payload(payload: Dict[str, Any]) -> bytes:
    storage = payload.get("storage")
    if not storage:
        raise ValueError("Storage location missing from payload")

    bucket = storage.get("bucket")
    key = storage.get("key")
    if not bucket or not key:
        raise ValueError("Storage location must include bucket and key")

    if not SUPABASE_URL or not SUPABASE_SERVICE_ROLE_KEY:
        raise ValueError("Supabase credentials are required to download storage objects")

    object_bytes = _download_storage_object(bucket, key)
    if object_bytes.startswith(b"%PDF"):
        return object_bytes

    text_payload = object_bytes.decode("utf-8", errors="ignore").strip()
    if not text_payload:
        raise ValueError("Downloaded storage object is empty")

    try:
        parsed = json.loads(text_payload)
    except json.JSONDecodeError:
        parsed = None

    if isinstance(parsed, dict):
        upload_response = parsed.get("uploadResponse")
        if isinstance(upload_response, dict) and isinstance(upload_response.get("uri"), str):
            text_payload = upload_response["uri"]

    if text_payload.startswith("data:"):
        comma_index = text_payload.find(",")
        if comma_index == -1:
            raise ValueError("Invalid data URI in storage object")
        text_payload = text_payload[comma_index + 1 :]

    base64_payload = text_payload.strip()
    if not base64_payload:
        raise ValueError("No base64 data found in storage object")

    try:
        return base64.b64decode(base64_payload, validate=False)
    except binascii.Error as exc:
        raise ValueError("Invalid base64 data in storage object") from exc


def _download_storage_object(bucket: str, key: str) -> bytes:
    encoded_key = quote(key.lstrip("/"), safe="/")
    url = f"{SUPABASE_URL}/storage/v1/object/{bucket}/{encoded_key}"
    request = Request(url)
    request.add_header("Authorization", f"Bearer {SUPABASE_SERVICE_ROLE_KEY}")
    request.add_header("apikey", SUPABASE_SERVICE_ROLE_KEY)

    with urlopen(request) as response:
        return response.read()
