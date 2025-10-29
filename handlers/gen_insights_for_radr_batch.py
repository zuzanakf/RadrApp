"""Generate AI insights for radr-user pairs in batches."""
from __future__ import annotations

import json
from typing import Any, Iterable

from pydantic import BaseModel, Field

from db import execute, fetchall, fetchone
from jobs import enqueue_job
from llm.client import parse_structured_response

ADVISORY_LOCK_SQL = "select pg_advisory_xact_lock(hashtextextended(%s, 0))"

OPENER_QUERY = """
    select
        p.current_role_title,
        p.past_experience,
        p.future_career_aspirations,
        p.professional_interests,
        p.professional_values,
        p.personal_interests,
        p.extracurriculars,
        p.tags,
        p.keywords_3
    from public.radrs r
    join public.profiles p on p.user_id = r.creator_user_id
    where r.id = %s
"""

CANDIDATES_QUERY = """
    select
        user_id,
        current_role_title,
        past_experience,
        future_career_aspirations,
        professional_interests,
        professional_values,
        personal_interests,
        extracurriculars,
        tags,
        keywords_3
    from public.profiles
    where user_id = any(%s)
"""

PENDING_USERS_QUERY = """
    select user_id
      from public.radr_user_scores
     where radr_id = %s
       and (three_things is null or explanation is null or common_tags is null)
     order by total_score desc nulls last
     limit %s
"""

UPDATE_INSIGHTS_SQL = """
    update public.radr_user_scores
       set three_things = %s::text[],
           explanation  = %s::jsonb,
           common_tags  = %s::text[],
           updated_at   = now()
     where radr_id = %s and user_id = %s
"""

REMAINING_COUNT_SQL = """
    select count(*) as missing
      from public.radr_user_scores
     where radr_id = %s
       and (three_things is null or explanation is null or common_tags is null)
"""


class InsightBioBlurbs(BaseModel):
    creator: str = ""
    joiner: str = ""


class InsightExplanation(BaseModel):
    why: str = ""
    bio_blurbs: InsightBioBlurbs = Field(default_factory=InsightBioBlurbs)


class InsightItem(BaseModel):
    user_id: str
    three_things: list[str] = Field(default_factory=list)
    explanation: InsightExplanation = Field(default_factory=InsightExplanation)
    common_tags: list[str] = Field(default_factory=list)


class InsightBatch(BaseModel):
    __root__: list[InsightItem] = Field(default_factory=list)


def handle(conn, job: dict[str, Any]) -> None:
    payload = job.get("payload_json") or {}
    radr_id = payload.get("radr_id")
    if not radr_id:
        return

    batch_size = int(payload.get("batch_size") or 5)
    if batch_size <= 0:
        batch_size = 5

    fetchone(conn, ADVISORY_LOCK_SQL, [radr_id])

    opener = fetchone(conn, OPENER_QUERY, [radr_id])
    if not opener:
        return

    pending = fetchall(conn, PENDING_USERS_QUERY, [radr_id, batch_size])
    if not pending:
        return

    candidate_ids = [row.get("user_id") for row in pending if row.get("user_id")]
    if not candidate_ids:
        return

    candidate_profiles = _fetch_candidate_profiles(conn, candidate_ids)
    if not candidate_profiles:
        return

    formatted_opener = _format_profile(opener)
    formatted_candidates = {
        user_id: _format_profile(profile)
        for user_id, profile in candidate_profiles.items()
    }

    llm_input_candidates = [
        {
            "user_id": user_id,
            "profile": formatted_candidates[user_id],
        }
        for user_id in candidate_ids
        if user_id in formatted_candidates
    ]

    if not llm_input_candidates:
        return

    llm_prompt = _build_prompt(formatted_opener, llm_input_candidates)

    try:
        response = parse_structured_response(
            model="gpt-4o-mini",
            messages=[
                {
                    "role": "system",
                    "content": (
                        "You generate insights connecting an opener and potential joiners. "
                        "Always return valid JSON matching the requested schema."
                    ),
                },
                {"role": "user", "content": llm_prompt},
            ],
            schema=InsightBatch,
        )
    except Exception:
        return

    items = list(getattr(response, "__root__", []) or [])

    for item in items:
        if item.user_id not in candidate_ids:
            continue

        three_things = [
            str(value).strip()
            for value in (item.three_things or [])
            if str(value).strip()
        ][:3]
        if len(three_things) < 1:
            continue

        explanation = {
            "why": item.explanation.why.strip(),
            "bio_blurbs": {
                "creator": item.explanation.bio_blurbs.creator.strip(),
                "joiner": item.explanation.bio_blurbs.joiner.strip(),
            },
        }

        common_tags = [
            str(value).strip()
            for value in (item.common_tags or [])
            if str(value).strip()
        ][:5]

        if not explanation["why"]:
            continue

        try:
            execute(
                conn,
                UPDATE_INSIGHTS_SQL,
                [
                    three_things,
                    json.dumps(explanation, ensure_ascii=False),
                    common_tags,
                    radr_id,
                    item.user_id,
                ],
            )
        except Exception:
            continue

    remaining = fetchone(conn, REMAINING_COUNT_SQL, [radr_id])
    missing = (remaining or {}).get("missing")
    if missing and int(missing) > 0:
        enqueue_job(
            conn,
            "gen_insights_for_radr_batch",
            {"radr_id": radr_id, "batch_size": batch_size},
        )


def _fetch_candidate_profiles(conn, user_ids: Iterable[str]) -> dict[str, dict[str, Any]]:
    rows = fetchall(conn, CANDIDATES_QUERY, [list(user_ids)])
    result: dict[str, dict[str, Any]] = {}
    for row in rows or []:
        user_id = row.get("user_id")
        if not user_id:
            continue
        result[user_id] = row
    return result


def _format_profile(profile: dict[str, Any]) -> str:
    if not profile:
        return ""

    parts: list[str] = []

    def add(label: str, key: str) -> None:
        value = profile.get(key)
        if value in (None, ""):
            return
        if isinstance(value, (list, tuple)):
            joined = ", ".join(str(item).strip() for item in value if str(item).strip())
            if not joined:
                return
            parts.append(f"{label}: {joined}")
        else:
            text = str(value).strip()
            if not text:
                return
            parts.append(f"{label}: {text}")

    add("Role", "current_role_title")
    add("Past", "past_experience")
    add("Future", "future_career_aspirations")
    add("Professional interests", "professional_interests")
    add("Professional values", "professional_values")
    add("Personal interests", "personal_interests")
    add("Extracurriculars", "extracurriculars")
    add("Tags", "tags")
    add("Keywords", "keywords_3")

    return "\n".join(parts)


def _build_prompt(opener_profile: str, candidates: list[dict[str, str]]) -> str:
    lines = [
        "Generate conversation insights for the opener and candidates.",
        "Return a JSON array where each item has keys: user_id, three_things (list of 3 strings, each <=16 words),",
        "explanation (object with keys 'why' and bio_blurbs with creator/joiner strings), and common_tags (5 items).",
        "Only include candidates with sufficient overlapping themes. Avoid fabricating details.",
        "Opener:",
        opener_profile or "(no data)",
        "",
        "Candidates:",
    ]

    for candidate in candidates:
        lines.append(f"- Candidate {candidate['user_id']}:")
        lines.append(candidate["profile"] or "(no data)")
        lines.append("")

    lines.append(
        "Produce the JSON array in the same order as presented candidates, omitting anyone you cannot confidently match."
    )

    return "\n".join(lines)
