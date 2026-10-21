"""Small shared Render/Space contract. No Hugging Face credentials required."""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
import time

MODEL = "htdemucs"
MAX_BYTES = 35 * 1024 * 1024
MAX_SECONDS = 600
GPU_SECONDS = 120


def _encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def issue(secret: str, claims: dict) -> str:
    body = _encode(json.dumps(claims, sort_keys=True, separators=(",", ":")).encode())
    signature = _encode(hmac.new(secret.encode(), body.encode(), hashlib.sha256).digest())
    return body + "." + signature


def verify(secret: str, ticket: str, audience: str, now: float | None = None) -> dict:
    if len(secret) < 32 or len(ticket) > 2048:
        raise ValueError("Invalid authorization")
    try:
        body, _ = ticket.split(".")
        expected = issue(secret, json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4))))
        if not hmac.compare_digest(expected, ticket):
            raise ValueError()
        claims = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
        timestamp = time.time() if now is None else now
        if (claims["aud"] != audience or claims["model"] != MODEL
                or not timestamp < claims["exp"] <= timestamp + 901
                or not 0 < claims["bytes"] <= MAX_BYTES
                or not 0 < claims["seconds"] < MAX_SECONDS
                or not re.fullmatch(r"[a-f0-9]{64}", claims["sha256"])
                or not re.fullmatch(r"[a-f0-9]{32}", claims["id"])):
            raise ValueError()
        return claims
    except (ValueError, TypeError, KeyError, UnicodeError):
        raise ValueError("Invalid or expired authorization") from None
