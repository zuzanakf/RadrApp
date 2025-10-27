"""Score an open radr for users currently checked in at its place."""
from __future__ import annotations

import json
from typing import Any, Optional, Sequence

from db import execute, fetchall, fetchone


ADVISORY_LOCK_SQL = "select pg_advisory_xact_lock(hashtextextended(%s, 0))"

RADR_QUERY = """
    select
        r.id,
        r.status,
        r.creator_user_id,
        r.place_id,
        e.prof_vec as r_prof_vec,
        e.personal_vec as r_personal_vec,
        e.profile_vec as r_profile_vec
    from public.radrs r
    left join public.radr_embeddings e on e.radr_id = r.id
    where r.id = %s
"""

CHECKINS_QUERY = """
    select user_id
      from public.place_checkins
     where place_id = %s
       and present is true
"""

USER_EMBEDDINGS_QUERY = """
    select
        prof_vec,
        personal_vec,
        profile_vec
      from public.user_embeddings
     where user_id = %s
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

ALLOWED_STATUSES = {"open", "pending"}


def handle(conn, job: dict[str, Any]) -> None:
    payload = job["payload_json"]
    radr_id = payload["radr_id"]

    fetchone(conn, ADVISORY_LOCK_SQL, [radr_id])

    radr = fetchone(conn, RADR_QUERY, [radr_id])
    if not radr:
        return

    status = (radr.get("status") or "").lower()
    if status not in ALLOWED_STATUSES:
        return

    place_id = radr.get("place_id")
    if not place_id:
        return

    r_prof_vec = _coerce_vector(radr.get("r_prof_vec"))
    r_personal_vec = _coerce_vector(radr.get("r_personal_vec"))
    r_profile_vec = _coerce_vector(radr.get("r_profile_vec"))

    if r_prof_vec is None or r_personal_vec is None or r_profile_vec is None:
        return

    creator_user_id = radr.get("creator_user_id")

    checkins = fetchall(conn, CHECKINS_QUERY, [place_id])
    if not checkins:
        return

    for row in checkins:
        user_id = row.get("user_id")
        if not user_id:
            continue

        if creator_user_id is not None and user_id == creator_user_id:
            continue

        user_embeddings = fetchone(conn, USER_EMBEDDINGS_QUERY, [user_id])
        if not user_embeddings:
            continue

        u_prof_vec = _coerce_vector(user_embeddings.get("prof_vec"))
        u_personal_vec = _coerce_vector(user_embeddings.get("personal_vec"))
        u_profile_vec = _coerce_vector(user_embeddings.get("profile_vec"))

        if (
            u_prof_vec is None
            or u_personal_vec is None
            or u_profile_vec is None
        ):
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
    left_list = list(float(value) for value in left)
    right_list = list(float(value) for value in right)
    if len(left_list) != len(right_list):
        raise ValueError(
            "Cannot compute dot product for vectors with different dimensions: "
            f"{len(left_list)} vs {len(right_list)}"
        )
    return sum(l * r for l, r in zip(left_list, right_list))


def _coerce_vector(vec: Any) -> Optional[list[float]]:
    if vec is None:
        return None

    if isinstance(vec, (list, tuple)):
        return [float(value) for value in vec]

    if hasattr(vec, "tolist"):
        return [float(value) for value in vec.tolist()]

    if isinstance(vec, memoryview):
        return [float(value) for value in vec.tolist()]

    if isinstance(vec, bytes):
        raise TypeError("Binary vector representations are not supported")

    if isinstance(vec, str):
        try:
            loaded = json.loads(vec)
        except json.JSONDecodeError as exc:  # pragma: no cover - defensive
            raise ValueError(f"Unable to decode vector string: {vec!r}") from exc
        return _coerce_vector(loaded)

    if hasattr(vec, "__iter__"):
        return [float(value) for value in vec]

    raise TypeError(f"Unsupported vector type: {type(vec)!r}")

