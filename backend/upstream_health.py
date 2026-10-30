"""Provider-scoped outbound health telemetry; never stores IPs, URLs or cookies.

An HTTP 429 from the music catalogue and a 429 from the extraction pipeline
are NOT interchangeable. Only confirmed upstream failures are recorded here.
The existing YouTube audio cooldown is owned by main.py and remains unchanged.
"""
from __future__ import annotations

import os
import re
import threading
import time

_PROVIDERS = ("ytmusic_search", "youtube_audio", "r2_cache")
_lock = threading.RLock()
_state = {
    provider: {"successes": 0, "failures": 0, "consecutive_failures": 0,
               "last_category": "none", "categories": {}, "cooldown_until": 0.0,
               "last_latency_ms": None}
    for provider in _PROVIDERS
}


def classify_error(error: BaseException) -> str:
    """Classify the OUTCOME, not an inferred IP reputation or copyright cause."""
    response = getattr(error, "response", None)
    status = getattr(response, "status_code", None)
    if status is None:
        status = getattr(error, "status_code", getattr(error, "code", None))
    if status == 429:
        return "rate_limited"
    if status == 403:
        return "access_denied"
    if status in (408, 504):
        return "timeout"
    message = str(error).lower()
    if re.search(r"(?:http (?:error |status )?|status code )429\b|too many requests", message):
        return "rate_limited"
    if re.search(r"(?:http (?:error |status )?|status code )403\b|forbidden", message):
        return "access_denied"
    if "not a bot" in message or "bot verification" in message:
        return "bot_verification"
    if isinstance(error, TimeoutError) or "timeout" in type(error).__name__.lower() or any(
        s in message for s in ("timed out", "read timeout", "connect timeout")
    ):
        return "timeout"
    if any(s in type(error).__name__.lower() for s in ("connectionerror", "connecterror")):
        return "connection_error"
    return "upstream_error"


def record_success(provider: str, latency_ms: int | None = None) -> None:
    with _lock:
        state = _state[provider]
        state["successes"] += 1
        state["consecutive_failures"] = 0
        state["last_category"] = "none"
        state["cooldown_until"] = 0.0
        if latency_ms is not None:
            state["last_latency_ms"] = max(0, int(latency_ms))


def record_failure(provider: str, error: BaseException) -> str:
    """Only search failures set a short provider cooldown; audio uses its own."""
    category = classify_error(error)
    with _lock:
        state = _state[provider]
        state["failures"] += 1
        state["consecutive_failures"] += 1
        state["last_category"] = category
        state["categories"][category] = state["categories"].get(category, 0) + 1
        if provider == "ytmusic_search":
            cooldown_seconds = {"rate_limited": 60, "bot_verification": 60,
                                "access_denied": 15}.get(category, 0)
            if cooldown_seconds:
                state["cooldown_until"] = max(
                    state["cooldown_until"], time.monotonic() + cooldown_seconds
                )
    return category


def cooldown(provider: str) -> tuple[int, str]:
    """Return provider cooldown and true reason, never infer IP blocking."""
    with _lock:
        state = _state[provider]
        seconds = state["cooldown_until"] - time.monotonic()
        category = state["last_category"]
    return max(0, int(seconds + 0.999)), category


def remaining(provider: str) -> int:
    return cooldown(provider)[0]


def snapshot() -> dict:
    """Aggregate, non-identifying counters suitable for /metrics."""
    with _lock:
        now = time.monotonic()
        return {
            provider: {
                "successes": value["successes"],
                "failures": value["failures"],
                "consecutive_failures": value["consecutive_failures"],
                "last_category": value["last_category"],
                "categories": dict(value["categories"]),
                "cooldown_seconds": max(0, int(value["cooldown_until"] - now + 0.999)),
                "last_latency_ms": value["last_latency_ms"],
            }
            for provider, value in _state.items()
        }


def egress_profile() -> dict:
    """Deployment metadata only, NOT a real IP or a claimed IP reputation."""
    configured = os.getenv("EGRESS_MODE", "").strip().lower()
    return {
        "mode": configured if configured in {"shared", "dedicated"} else "unverified",
        "region": re.sub(r"[^a-z0-9_-]", "", os.getenv("RENDER_REGION", "unknown").lower())[:32]
                  or "unknown",
        "ip_rotation": False,
        "ip_reputation": "not_measured",
    }


def reset_for_tests() -> None:
    with _lock:
        for value in _state.values():
            value.update(successes=0, failures=0, consecutive_failures=0,
                         last_category="none", categories={}, cooldown_until=0.0,
                         last_latency_ms=None)
