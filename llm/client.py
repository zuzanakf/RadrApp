from openai import OpenAI
from config import OPENAI_API_KEY

client = OpenAI(api_key=OPENAI_API_KEY)

def chat_json(model: str, system: str, user: str):
    resp = client.chat.completions.create(
        model=model,
        messages=[{"role":"system","content":system},{"role":"user","content":user}],
        response_format={"type":"json_object"}
    )
    import json
    return json.loads(resp.choices[0].message.content)
