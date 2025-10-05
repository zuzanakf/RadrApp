"""Job handler to compute embeddings for user profiles."""
from __future__ import annotations

import math
from typing import Any, Iterable, Optional, Sequence

from config import EMBEDDING_DIMS, EMBEDDING_MODEL
from db import execute, fetchone
from llm.client import client


PROFILE_QUERY = """
    select
        current_role_title,
        past_experience,
        future_career_aspirations,
        professional_interests,
        professional_values,
        personal_interests,
        extracurriculars
      from public.profiles
     where user_id = %s
"""


def handle(conn, job: dict[str, Any]) -> None:
    payload = job["payload_json"]
    user_id = payload["user_id"]

    profile = fetchone(conn, PROFILE_QUERY, [user_id])
    if not profile:
        raise ValueError(f"Profile not found for user {user_id}")

    career_text = _join_fields(
        profile.get("current_role_title"),
        profile.get("past_experience"),
    )
    goals_text = _join_fields(
        profile.get("future_career_aspirations"),
        profile.get("professional_values"),
    )
    interests_text = _join_fields(
        profile.get("professional_interests"),
        profile.get("personal_interests"),
        profile.get("extracurriculars"),
    )

    career_vec = _compute_embedding(career_text)
    goals_vec = _compute_embedding(goals_text)
    interests_vec = _compute_embedding(interests_text)

    insert_sql, params = _build_upsert_sql(user_id, career_vec, goals_vec, interests_vec)
    execute(conn, insert_sql, params)


def _compute_embedding(text: str) -> Optional[list[float]]:
    text = (text or "").strip()
    if not text:
        return None

    response = client.embeddings.create(
        model=EMBEDDING_MODEL,
        input=text,
        encoding_format="float",
    )
    embedding = _convert_embedding_dimensions(response.data[0].embedding)

    return embedding


def _convert_embedding_dimensions(embedding: Sequence[float]) -> list[float]:
    if EMBEDDING_DIMS is None:
        return list(float(value) for value in embedding)

    if len(embedding) < EMBEDDING_DIMS:
        raise ValueError(
            f"Embedding dimension mismatch: cannot convert {len(embedding)}-d vector "
            f"to {EMBEDDING_DIMS} dimensions"
        )

    trimmed = [float(value) for value in embedding[:EMBEDDING_DIMS]]
    return _normalize_l2(trimmed)


def _normalize_l2(values: Sequence[float]) -> list[float]:
    norm = math.sqrt(sum(value * value for value in values))
    if norm == 0:
        return list(values)
    return [value / norm for value in values]


def _build_upsert_sql(
    user_id: str,
    career_vec: Optional[list[float]],
    goals_vec: Optional[list[float]],
    interests_vec: Optional[list[float]],
) -> tuple[str, list[Any]]:
    career_expr, career_params = _vector_expression(career_vec)
    goals_expr, goals_params = _vector_expression(goals_vec)
    interests_expr, interests_params = _vector_expression(interests_vec)

    sql = f"""
        insert into public.user_embeddings (user_id, career_vec, goals_vec, interests_vec)
        values (%s, {career_expr}, {goals_expr}, {interests_expr})
        on conflict (user_id) do update set
            career_vec = excluded.career_vec,
            goals_vec = excluded.goals_vec,
            interests_vec = excluded.interests_vec
    """
    params = [user_id] + career_params + goals_params + interests_params
    return sql, params


def _vector_expression(vec: Optional[list[float]]) -> tuple[str, list[str]]:
    if vec is None:
        return "NULL", []
    literal = _vector_literal(vec)
    return "%s::vector", [literal]


def _vector_literal(vec: Iterable[float]) -> str:
    return "[" + ",".join(_format_float(value) for value in vec) + "]"


def _format_float(value: float) -> str:
    return (f"{value:.10f}".rstrip("0").rstrip(".")) or "0"


def _join_fields(*values: Any) -> str:
    parts: list[str] = []
    for value in values:
        text = _stringify(value)
        if text:
            parts.append(text)
    return "\n\n".join(parts)


def _stringify(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, (list, tuple, set)):
        return ", ".join(str(item).strip() for item in value if str(item).strip())
    if isinstance(value, dict):
        return ", ".join(
            f"{key}: {val}" for key, val in value.items() if val not in (None, "")
        )
    return str(value).strip()