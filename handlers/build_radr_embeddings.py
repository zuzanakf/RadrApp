"""Job handler to build embeddings for radrs."""
from __future__ import annotations

from typing import Any, Iterable, Optional, Sequence

from config import EMBEDDING_DIMS, EMBEDDING_MODEL
from db import execute, fetchone
from llm.client import client


RADR_QUERY = """
    select
        id,
        creator_user_id,
        status,
        intentions,
        bio
      from public.radrs
     where id = %s
"""

USER_EMBEDDINGS_QUERY = """
    select
        career_vec,
        goals_vec,
        interests_vec
      from public.user_embeddings
     where user_id = %s
"""

UPSERT_SQL_TEMPLATE = """
    insert into public.radr_embeddings (radr_id, career_vec, goals_vec, interests_vec)
    values (%s, {career_expr}, {goals_expr}, {interests_expr})
    on conflict (radr_id) do update
    set career_vec = excluded.career_vec,
        goals_vec = excluded.goals_vec,
        interests_vec = excluded.interests_vec,
        updated_at = now()
"""


ALLOWED_STATUSES = {"open", "pending"}


def handle(conn, job: dict[str, Any]) -> None:
    payload = job["payload_json"]
    radr_id = payload["radr_id"]

    radr = fetchone(conn, RADR_QUERY, [radr_id])
    if not radr:
        raise ValueError(f"Radr not found for id {radr_id}")

    status = (radr.get("status") or "").lower()
    if status not in ALLOWED_STATUSES:
        return

    creator_user_id = radr.get("creator_user_id")
    if not creator_user_id:
        raise ValueError(f"Radr {radr_id} missing creator_user_id")

    user_embeddings = fetchone(conn, USER_EMBEDDINGS_QUERY, [creator_user_id]) or {}

    user_career_vec = _coerce_vector(user_embeddings.get("career_vec"))
    user_goals_vec = _coerce_vector(user_embeddings.get("goals_vec"))
    user_interests_vec = _coerce_vector(user_embeddings.get("interests_vec"))

    intent_text = _join_fields(radr.get("intentions"), radr.get("bio"))
    intent_vec = embed_text(intent_text)

    career_vec = _blend_vectors(user_career_vec, intent_vec)
    goals_vec = _blend_vectors(user_goals_vec, intent_vec)
    interests_vec = _blend_vectors(user_interests_vec, intent_vec)

    insert_sql, params = _build_upsert_sql(radr_id, career_vec, goals_vec, interests_vec)
    execute(conn, insert_sql, params)


def embed_text(text: str) -> Optional[list[float]]:
    text = (text or "").strip()
    if not text:
        return None

    response = client.embeddings.create(
        model=EMBEDDING_MODEL,
        input=text,
        encoding_format="float",
    )
    embedding = response.data[0].embedding
    return _convert_embedding_dimensions(embedding)


def _convert_embedding_dimensions(embedding: Sequence[float]) -> list[float]:
    if EMBEDDING_DIMS is None:
        return [float(value) for value in embedding]

    if len(embedding) < EMBEDDING_DIMS:
        raise ValueError(
            f"Embedding dimension mismatch: cannot convert {len(embedding)}-d vector "
            f"to {EMBEDDING_DIMS} dimensions"
        )

    trimmed = [float(value) for value in embedding[:EMBEDDING_DIMS]]
    return _normalize_l2(trimmed)


def _normalize_l2(values: Sequence[float]) -> list[float]:
    norm = sum(value * value for value in values) ** 0.5
    if norm == 0:
        return [float(value) for value in values]
    return [float(value) / norm for value in values]


def _blend_vectors(
    base_vec: Optional[Sequence[float]], intent_vec: Optional[Sequence[float]]
) -> Optional[list[float]]:
    if base_vec is None and intent_vec is None:
        return None
    if base_vec is None:
        return _normalize_l2(list(intent_vec)) if intent_vec is not None else None
    if intent_vec is None:
        return _normalize_l2(list(base_vec))

    base_list = list(float(value) for value in base_vec)
    intent_list = list(float(value) for value in intent_vec)
    if len(base_list) != len(intent_list):
        raise ValueError(
            "Cannot blend vectors with different dimensions: "
            f"{len(base_list)} vs {len(intent_list)}"
        )

    blended = [(b + i) / 2 for b, i in zip(base_list, intent_list)]
    return _normalize_l2(blended)


def _coerce_vector(vec: Any) -> Optional[list[float]]:
    if vec is None:
        return None

    if isinstance(vec, (list, tuple)):
        return [float(value) for value in vec]

    if hasattr(vec, "tolist"):
        return [float(value) for value in vec.tolist()]

    if hasattr(vec, "__iter__"):
        return [float(value) for value in vec]

    raise TypeError(f"Unsupported vector type: {type(vec)!r}")


def _build_upsert_sql(
    radr_id: str,
    career_vec: Optional[list[float]],
    goals_vec: Optional[list[float]],
    interests_vec: Optional[list[float]],
) -> tuple[str, list[Any]]:
    career_expr, career_params = _vector_expression(career_vec)
    goals_expr, goals_params = _vector_expression(goals_vec)
    interests_expr, interests_params = _vector_expression(interests_vec)

    sql = UPSERT_SQL_TEMPLATE.format(
        career_expr=career_expr,
        goals_expr=goals_expr,
        interests_expr=interests_expr,
    )

    params: list[Any] = [radr_id]
    params.extend(career_params)
    params.extend(goals_params)
    params.extend(interests_params)
    return sql, params


def _vector_expression(vec: Optional[list[float]]) -> tuple[str, list[str]]:
    if vec is None:
        return "NULL", []
    literal = _vector_literal(vec)
    return "%s::vector", [literal]


def _vector_literal(vec: Iterable[float]) -> str:
    return "[" + ",".join(_format_float(value) for value in vec) + "]"


def _format_float(value: float) -> str:
    return (f"{float(value):.10f}".rstrip("0").rstrip(".")) or "0"


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
        items = [str(item).strip() for item in value if str(item).strip()]
        return ", ".join(items)
    if isinstance(value, dict):
        return ", ".join(
            f"{key}: {val}" for key, val in value.items() if val not in (None, "")
        )
    return str(value).strip()
