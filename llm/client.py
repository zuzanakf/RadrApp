from openai import OpenAI
from config import OPENAI_API_KEY

client = OpenAI(api_key=OPENAI_API_KEY)


def chat_json(model: str, system: str, user: str):
    """Call the OpenAI Responses API and parse the JSON output."""

    response = client.responses.create(
        model=model,
        input=[
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        response_format={"type": "json_object"},
    )

    import json

    return json.loads(response.output_text)
