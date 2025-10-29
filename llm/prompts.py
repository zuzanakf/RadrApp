CV_STRUCTURED_PROMPT = """You are an expert CV analyst. Read the provided CV text.
Return a compact JSON with these exact keys:
{{
  "current_role_title": str,
  "past_experience": str,               # 2-4 lines summary
  "future_career_aspirations": str,
  "professional_interests": [str],      # 3-8 items, lowercase nouns
  "professional_values": [str],         # 3-8 items, lowercase
  "personal_interests": [str],          # hobbies etc., 3-8 items
  "extracurriculars": [str],            # clubs/associations, 0-8
  "keywords_20": [str],                 # 20 single or two-word keywords
  "keywords_3": [str]                   # exactly 3 short tags
}}
Write in third person. Use detailed language. If unsure, return [] or "" for that field, do not make up information.
CV TEXT:
<<<
{cv_text}
>>>
"""

TAGS_NORMALIZER_PROMPT = """Canonicalize the following free-text lists into lowercase, comma-separated canonical tags.
Prefer concise nouns; avoid duplicates, plurals, or synonyms.
Input JSON:
{input_json}
Return JSON with the SAME KEYS, but each list normalized (lowercase, deduped, canonicalized).
"""

THREE_THINGS_PROMPT = """You are helping two professionals meet at a members club.
Given two short profiles (A and B), suggest exactly THREE distinct, specific conversation starters they could use.
Focus on overlaps across skills/interests/values/goals; keep each item <= 16 words.
Return a JSON list of three strings.

PROFILE A:
{profile_a}

PROFILE B:
{profile_b}
"""


GEN_INSIGHTS_SYSTEM_PROMPT = (
    "You generate insights connecting an opener and potential joiners. "
    "Always return valid JSON matching the requested schema."
)


def build_gen_insights_prompt(
    opener_profile: str, candidates: list[dict[str, str]]
) -> str:
    lines = [
        "Generate conversation insights for the opener and candidates.",
        "Return a JSON array where each item has keys: user_id, three_things (list of 3 strings, each <=16 words),",
        "explanation (object with keys 'why' and bio_blurbs with creator/joiner strings), and common_tags (5 items).",
        "Only include candidates with sufficient overlapping themes. Avoid fabricating details.",
        "Use the candidate IDs exactly as provided (for example, C1) in the user_id field of the JSON output.",
        "Opener:",
        opener_profile or "(no data)",
        "",
        "Candidates:",
    ]

    for candidate in candidates:
        lines.append(f"- Candidate {candidate['alias']}:")
        lines.append(candidate.get("profile") or "(no data)")
        lines.append("")

    lines.append(
        "Produce the JSON array in the same order as presented candidates, omitting anyone you cannot confidently match."
    )

    return "\n".join(lines)
