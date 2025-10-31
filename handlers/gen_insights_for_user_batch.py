"""Generate AI insights for user-radr pairs in batches."""
from __future__ import annotations

import json
import logging
from typing import Any, Iterable

from pydantic import BaseModel, Field

from db import execute, fetchall, fetchone
from jobs import enqueue_job
from llm.client import parse_structured_response
from llm.prompts import GEN_INSIGHTS_SYSTEM_PROMPT, build_gen_insights_prompt

logger = logging.getLogger(__name__)

ADVISORY_LOCK_SQL = "select pg_advisory_xact_lock(hashtextextended(%s::text, 0))"

OPENER_QUERY = """
    select
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
    where user_id = %s
"""

PENDING_RADRS_QUERY = """
    select
        rus.radr_id,
        r.creator_user_id
      from public.radr_user_scores rus
      join public.radrs r on r.id = rus.radr_id
     where rus.user_id = %s
       and lower(coalesce(r.status, '')) = 'open'
       and lower(coalesce(rus.status, '')) = 'pending'
       and (rus.three_things is null or rus.explanation is null or rus.common_tags is null)
     order by rus.total_score desc nulls last
     limit %s
"""

RADR_CREATOR_PROFILES_QUERY = """
    select
        r.id as radr_id,
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
     where r.id = any(%s)
"""

UPDATE_INSIGHTS_SQL = """
    update public.radr_user_scores
       set three_things = %s::text[],
           explanation  = %s::jsonb,
           common_tags  = %s::text[],
           updated_at   = now()
     where user_id = %s and radr_id = %s
"""

REMAINING_COUNT_SQL = """
    select count(*) as missing
      from public.radr_user_scores
     where user_id = %s
       and lower(coalesce(status, '')) = 'pending'
       and (three_things is null or explanation is null or common_tags is null)
"""


def _summarize_list(values: Iterable[Any], limit: int = 3) -> list[Any]:
    items = [value for value in values if value not in (None, "")]
    if len(items) <= limit:
        return items
    remaining = len(items) - limit
    return [*items[:limit], f"...(+{remaining})"]


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
    items: list[InsightItem] = Field(default_factory=list)


DEFAULT_BATCH_SIZE = 5
MAX_CANDIDATES_PER_REQUEST = 5


def handle(conn, job: dict[str, Any]) -> None:
    payload = job.get("payload_json") or {}
    user_id = payload.get("user_id")
    if not user_id:
        return

    raw_batch_size = payload.get("batch_size")
    try:
        batch_size = int(raw_batch_size or DEFAULT_BATCH_SIZE)
    except (TypeError, ValueError):
        batch_size = DEFAULT_BATCH_SIZE

    if batch_size <= 0:
        batch_size = DEFAULT_BATCH_SIZE

    if batch_size > MAX_CANDIDATES_PER_REQUEST:
        logger.debug(
            "Capping batch size from %s to %s for user %s",
            batch_size,
            MAX_CANDIDATES_PER_REQUEST,
            user_id,
        )
        batch_size = MAX_CANDIDATES_PER_REQUEST

    fetchone(conn, ADVISORY_LOCK_SQL, [user_id])

    opener = fetchone(conn, OPENER_QUERY, [user_id])
    if not opener:
        return

    pending = fetchall(conn, PENDING_RADRS_QUERY, [user_id, batch_size])
    pending_radr_ids = [
        str(row.get("radr_id"))
        for row in pending or []
        if row.get("radr_id") not in (None, "")
    ]
    logger.debug(
        "Pending rows for user %s (count=%s, sample_radr_ids=%s)",
        user_id,
        len(pending or []),
        _summarize_list(pending_radr_ids),
    )
    if not pending:
        return

    candidate_ids = [
        str(row.get("radr_id"))
        for row in pending
        if row.get("radr_id") not in (None, "")
    ]
    logger.debug(
        "Candidate radr ids for user %s (count=%s, sample=%s)",
        user_id,
        len(candidate_ids),
        _summarize_list(candidate_ids),
    )
    if not candidate_ids:
        return

    candidate_profiles = _fetch_candidate_profiles(conn, candidate_ids)
    logger.debug(
        "Fetched candidate profiles for user %s (count=%s, sample_radr_ids=%s)",
        user_id,
        len(candidate_profiles or {}),
        _summarize_list((candidate_profiles or {}).keys()),
    )
    if not candidate_profiles:
        return

    formatted_opener = _format_profile(opener)
    formatted_candidates = {
        radr_id: _format_candidate_profile(radr_id, profile)
        for radr_id, profile in candidate_profiles.items()
    }
    logger.debug(
        "Formatted candidates for user %s (count=%s, sample_radr_ids=%s)",
        user_id,
        len(formatted_candidates),
        _summarize_list(formatted_candidates.keys()),
    )

    alias_to_radr_id: dict[str, str] = {}
    llm_input_candidates = []
    for index, radr_id in enumerate(candidate_ids, start=1):
        profile = formatted_candidates.get(radr_id)
        if not profile:
            continue
        alias = f"R{index}"
        alias_to_radr_id[alias] = radr_id
        llm_input_candidates.append(
            {
                "alias": alias,
                "profile": profile,
            }
        )

    logger.debug(
        "LLM input candidates for user %s (count=%s, sample_aliases=%s)",
        user_id,
        len(llm_input_candidates),
        _summarize_list([item.get("alias") for item in llm_input_candidates]),
    )

    if not llm_input_candidates:
        return

    llm_prompt = build_gen_insights_prompt(formatted_opener, llm_input_candidates)

    try:
        response = parse_structured_response(
            model="gpt-4o-mini",
            messages=[
                {"role": "system", "content": GEN_INSIGHTS_SYSTEM_PROMPT},
                {"role": "user", "content": llm_prompt},
            ],
            schema=InsightBatch,
        )
    except Exception:
        logger.exception("Failed to parse structured response for user %s", user_id)
        return

    batch_items = getattr(response, "items", None)
    if batch_items is None:
        batch_items = getattr(response, "root", getattr(response, "__root__", []))

    items = list(batch_items or [])

    valid_response_ids = set(alias_to_radr_id.keys()) | set(candidate_ids)

    for item in items:
        raw_radr_id = getattr(item, "user_id", "")
        response_radr_id = str(raw_radr_id).strip()
        if not response_radr_id:
            logger.warning(
                "Skipping item with missing radr_id for user %s. Raw item: %s",
                user_id,
                _serialize_insight_item(item),
            )
            continue

        if response_radr_id not in valid_response_ids:
            logger.warning(
                "Skipping radr %s for user %s because it was not requested. Raw item: %s",
                response_radr_id,
                user_id,
                _serialize_insight_item(item),
            )
            continue

        radr_id = alias_to_radr_id.get(response_radr_id, response_radr_id)

        if radr_id not in candidate_ids:
            logger.warning(
                "Skipping radr %s for user %s due to unresolved mapping. Raw item: %s",
                response_radr_id,
                user_id,
                _serialize_insight_item(item),
            )
            continue

        three_things = [
            str(value).strip()
            for value in (item.three_things or [])
            if str(value).strip()
        ][:3]
        if len(three_things) < 1:
            logger.warning(
                "Skipping radr %s for user %s due to empty three_things. Raw item: %s",
                radr_id,
                user_id,
                _serialize_insight_item(item),
            )
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
            logger.warning(
                "Skipping radr %s for user %s due to empty why. Raw item: %s",
                radr_id,
                user_id,
                _serialize_insight_item(item),
            )
            continue

        try:
            execute(
                conn,
                UPDATE_INSIGHTS_SQL,
                [
                    three_things,
                    json.dumps(explanation, ensure_ascii=False),
                    common_tags,
                    user_id,
                    radr_id,
                ],
            )
        except Exception:
            logger.exception(
                "Failed to update insights for user %s radr %s", user_id, radr_id
            )
            raise

    remaining = fetchone(conn, REMAINING_COUNT_SQL, [user_id])
    missing = (remaining or {}).get("missing")
    if missing and int(missing) > 0:
        enqueue_job(
            conn,
            "gen_insights_for_user_batch",
            {"user_id": user_id, "batch_size": batch_size},
        )


def _fetch_candidate_profiles(conn, radr_ids: Iterable[str]) -> dict[str, dict[str, Any]]:
    rows = fetchall(conn, RADR_CREATOR_PROFILES_QUERY, [list(radr_ids)])
    result: dict[str, dict[str, Any]] = {}
    for row in rows or []:
        radr_id = row.get("radr_id")
        if radr_id in (None, ""):
            continue
        result[str(radr_id)] = row
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


def _format_candidate_profile(radr_id: str, profile: dict[str, Any]) -> str:
    formatted_profile = _format_profile(profile)
    if not formatted_profile:
        return f"Radr ID: {radr_id}"
    return f"Radr ID: {radr_id}\n{formatted_profile}"


def _serialize_insight_item(item: InsightItem) -> dict[str, Any]:
    """Convert an InsightItem (or similar) to a serializable dictionary."""

    if hasattr(item, "model_dump"):
        return item.model_dump()  # type: ignore[return-value]
    if hasattr(item, "dict"):
        return item.dict()  # type: ignore[return-value]
    return {
        "user_id": getattr(item, "user_id", None),
        "three_things": getattr(item, "three_things", None),
        "explanation": getattr(item, "explanation", None),
        "common_tags": getattr(item, "common_tags", None),
    }
