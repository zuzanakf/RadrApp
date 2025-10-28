"""Score a user against all open radrs at a specific place."""
from __future__ import annotations

import json
import re
from typing import Any, Optional, Sequence

from db import execute, fetchall, fetchone


ADVISORY_LOCK_SQL = "select pg_advisory_xact_lock(hashtextextended(%s, 0))"

USER_EMBEDDINGS_QUERY = """
    select
        prof_vec,
        personal_vec,
        profile_vec
      from public.user_embeddings
     where user_id = %s
"""

RADRS_QUERY = """
    select
        r.id,
        r.creator_user_id,
        e.prof_vec as r_prof_vec,
        e.personal_vec as r_personal_vec,
        e.profile_vec as r_profile_vec
      from public.radrs r
      left join public.radr_embeddings e on e.radr_id = r.id
     where r.place_id = %s
       and lower(coalesce(r.status, '')) = 'open'
       and r.creator_user_id is distinct from %s
"""

UPSERT_SCORE_SQL = """
    insert into public.radr_user_scores (
        radr_id,
        user_id,
        professional_score,
        personal_score,
        overall_score,
        total_score
    )
    values (%s, %s, %s, %s, %s, %s)
    on conflict (radr_id, user_id) do update
    set professional_score = excluded.professional_score,
        personal_score = excluded.personal_score,
        overall_score = excluded.overall_score,
        total_score = excluded.total_score
"""


def handle(conn, job: dict[str, Any]) -> None:
    payload = job["payload_json"]

    user_id = payload.get("user_id")
    if not user_id:
        return

    fetchone(conn, ADVISORY_LOCK_SQL, [user_id])

    user_embeddings = fetchone(conn, USER_EMBEDDINGS_QUERY, [user_id])
    if not user_embeddings:
        return

    u_prof_vec = _coerce_vector(user_embeddings.get("prof_vec"))
    u_personal_vec = _coerce_vector(user_embeddings.get("personal_vec"))
    u_profile_vec = _coerce_vector(user_embeddings.get("profile_vec"))

    if u_prof_vec is None or u_personal_vec is None or u_profile_vec is None:
        return

    place_id = payload.get("place_id")
    if not place_id:
        return

    radrs = fetchall(conn, RADRS_QUERY, [place_id, user_id])
    if not radrs:
        return

    for radr in radrs:
        radr_id = radr.get("id")
        if not radr_id:
            continue

        r_prof_vec = _coerce_vector(radr.get("r_prof_vec"))
        r_personal_vec = _coerce_vector(radr.get("r_personal_vec"))
        r_profile_vec = _coerce_vector(radr.get("r_profile_vec"))

        if r_prof_vec is None or r_personal_vec is None or r_profile_vec is None:
            continue

        try:
            professional = _dot(u_prof_vec, r_prof_vec)
            personal = _dot(u_personal_vec, r_personal_vec)
            overall = _dot(u_profile_vec, r_profile_vec)
        except ValueError:
            continue

        total = 0.5 * overall + 0.3 * professional + 0.2 * personal

        execute(
            conn,
            UPSERT_SCORE_SQL,
            [
                radr_id,
                user_id,
                professional,
                personal,
                overall,
                total,
            ],
        )


def _dot(left: Sequence[float], right: Sequence[float]) -> float:
    left_list = [float(value) for value in left]
    right_list = [float(value) for value in right]
    if len(left_list) != len(right_list):
        raise ValueError(
            "Cannot compute dot product for vectors with different dimensions: "
            f"{len(left_list)} vs {len(right_list)}"
        )
    return sum(l * r for l, r in zip(left_list, right_list))


def _coerce_vector(vec: Any) -> Optional[list[float]]:
    if vec is None:
        return None

    if isinstance(vec, str):
        stripped = vec.strip()
        if not stripped:
            return None

        try:
            loaded: Any = json.loads(stripped)
        except json.JSONDecodeError:
            cleaned = stripped
            if cleaned.startswith("{") and cleaned.endswith("}"):
                cleaned = "[" + cleaned[1:-1] + "]"
            elif not (cleaned.startswith("[") and cleaned.endswith("]")):
                cleaned = "[" + cleaned + "]"
            cleaned = re.sub(r"\s+", "", cleaned)
            try:
                loaded = json.loads(cleaned)
            except json.JSONDecodeError as exc:  # pragma: no cover - defensive
                raise ValueError(f"Unable to decode vector string: {vec!r}") from exc
        return _coerce_vector(loaded)

    if isinstance(vec, (list, tuple)):
        return [float(value) for value in vec]

    if hasattr(vec, "tolist"):
        return [float(value) for value in vec.tolist()]

    if isinstance(vec, memoryview):
        return [float(value) for value in vec.tolist()]

    if isinstance(vec, bytes):
        raise TypeError("Binary vector representations are not supported")

    if hasattr(vec, "__iter__"):
        return [float(value) for value in vec]

    raise TypeError(f"Unsupported vector type: {type(vec)!r}")
