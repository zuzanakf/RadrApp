from __future__ import annotations

from typing import Any, Sequence, Type, TypeVar

from openai import OpenAI
from pydantic import BaseModel

from config import OPENAI_API_KEY

client = OpenAI(api_key=OPENAI_API_KEY)

T = TypeVar("T", bound=BaseModel)


def parse_structured_response(
    model: str,
    messages: Sequence[dict[str, Any]],
    schema: Type[T],
    **kwargs: Any,
) -> T:
    """Call the OpenAI Responses API and parse the structured output.

    Parameters
    ----------
    model:
        The model identifier to use for the request.
    messages:
        A sequence of role/content dictionaries to send to the model.
    schema:
        The Pydantic model representing the expected structured response.
    **kwargs:
        Additional keyword arguments forwarded to ``client.responses.parse``.
    """

    response = client.responses.parse(
        model=model,
        input=list(messages),
        text_format=schema,
        **kwargs,
    )

    return response.output_parsed
