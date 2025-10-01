CV_STRUCTURED_PROMPT = """You are an expert CV analyst. Read the provided CV text.
Return a compact JSON with these exact keys:
{
  "current_role": str,
  "past_experience": str,               # 2-4 lines summary
  "future_career_aspirations": str,
  "professional_interests": [str],      # 3-8 items, lowercase nouns
  "professional_values": [str],         # 3-8 items, lowercase
  "personal_interests": [str],          # hobbies etc., 3-8 items
  "extracurriculars": [str],            # clubs/associations, 0-8
  "keywords_20": [str],                 # 20 single or two-word keywords
  "keywords_3": [str]                   # exactly 3 short tags
}
Use concise language. If unsure, return [] or "" for that field.
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
