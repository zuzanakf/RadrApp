"""Generate AI insights for radr-user pairs in batches."""
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


DEFAULT_BATCH_SIZE = 3
MAX_CANDIDATES_PER_REQUEST = 3


def handle(conn, job: dict[str, Any]) -> None:
    payload = job.get("payload_json") or {}
    radr_id = payload.get("radr_id")
    if not radr_id:
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
            "Capping batch size from %s to %s for radr %s",
            batch_size,
            MAX_CANDIDATES_PER_REQUEST,
            radr_id,
        )
        batch_size = MAX_CANDIDATES_PER_REQUEST

    fetchone(conn, ADVISORY_LOCK_SQL, [radr_id])

    opener = fetchone(conn, OPENER_QUERY, [radr_id])
    if not opener:
        return

    pending = fetchall(conn, PENDING_USERS_QUERY, [radr_id, batch_size])
    pending_user_ids = [
        str(row.get("user_id"))
        for row in pending or []
        if row.get("user_id") not in (None, "")
    ]
    logger.debug(
        "Pending rows for radr %s (count=%s, sample_user_ids=%s)",
        radr_id,
        len(pending or []),
        _summarize_list(pending_user_ids),
    )
    if not pending:
        return

    candidate_ids = [
        str(row.get("user_id"))
        for row in pending
        if row.get("user_id") not in (None, "")
    ]
    logger.debug(
        "Candidate ids for radr %s (count=%s, sample=%s)",
        radr_id,
        len(candidate_ids),
        _summarize_list(candidate_ids),
    )
    if not candidate_ids:
        return

    candidate_profiles = _fetch_candidate_profiles(conn, candidate_ids)
    logger.debug(
        "Fetched candidate profiles for radr %s (count=%s, sample_user_ids=%s)",
        radr_id,
        len(candidate_profiles or {}),
        _summarize_list((candidate_profiles or {}).keys()),
    )
    if not candidate_profiles:
        return

    formatted_opener = _format_profile(opener)
    formatted_candidates = {
        user_id: _format_profile(profile)
        for user_id, profile in candidate_profiles.items()
    }
    logger.debug(
        "Formatted candidates for radr %s (count=%s, sample_user_ids=%s)",
        radr_id,
        len(formatted_candidates),
        _summarize_list(formatted_candidates.keys()),
    )

    alias_to_user_id: dict[str, str] = {}
    llm_input_candidates = []
    for index, user_id in enumerate(candidate_ids, start=1):
        profile = formatted_candidates.get(user_id)
        if not profile:
            continue
        alias = f"C{index}"
        alias_to_user_id[alias] = user_id
        llm_input_candidates.append({
            "alias": alias,
            "profile": profile,
        })

    logger.debug(
        "LLM input candidates for radr %s (count=%s, sample_user_ids=%s)",
        radr_id,
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
        logger.exception("Failed to parse structured response for radr %s", radr_id)
        return

    batch_items = getattr(response, "items", None)
    if batch_items is None:
        batch_items = getattr(response, "root", getattr(response, "__root__", []))

    items = list(batch_items or [])

    valid_response_ids = set(alias_to_user_id.keys()) | set(candidate_ids)

    for item in items:
        raw_user_id = getattr(item, "user_id", "")
        response_user_id = str(raw_user_id).strip()
        if not response_user_id:
            logger.warning(
                "Skipping item with missing user_id for radr %s. Raw item: %s",
                radr_id,
                _serialize_insight_item(item),
            )
            continue

        if response_user_id not in valid_response_ids:
            logger.warning(
                "Skipping user %s for radr %s because it was not requested. Raw item: %s",
                response_user_id,
                radr_id,
                _serialize_insight_item(item),
            )
            continue

        user_id = alias_to_user_id.get(response_user_id, response_user_id)

        if user_id not in candidate_ids:
            logger.warning(
                "Skipping user %s for radr %s due to unresolved mapping. Raw item: %s",
                response_user_id,
                radr_id,
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
                "Skipping user %s for radr %s due to empty three_things. Raw item: %s",
                user_id,
                radr_id,
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
                "Skipping user %s for radr %s due to empty why. Raw item: %s",
                user_id,
                radr_id,
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
                    radr_id,
                    user_id,
                ],
            )
        except Exception:
            logger.exception(
                "Failed to update insights for radr %s user %s", radr_id, user_id
            )
            raise

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
        if user_id in (None, ""):
            continue
        result[str(user_id)] = row
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
