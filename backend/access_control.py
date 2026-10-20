"""Bounded per-client admission control; optional shared token for dev builds."""

from __future__ import annotations

from collections import deque
import hashlib
import os
import threading
import time


class AccessControl:
    def __init__(self, env: dict[str, str] | None = None):
        env = os.environ if env is None else env
        self.tokens = frozenset(token.strip() for token in env.get("GNARLY_ACCESS_TOKENS", "").split(",")
                                if token.strip())
        self.strict = env.get("GNARLY_AUTH_MODE", "permissive").lower() == "strict"
        self.per_minute = max(1, int(env.get("GNARLY_REQUESTS_PER_MINUTE", "120")))
        self.per_day = max(1, int(env.get("GNARLY_REQUESTS_PER_DAY", "500")))
        self._events: dict[str, deque[float]] = {}
        self._lock = threading.Lock()

    def check(self, token: str | None, client_ip: str, now: float | None = None) -> tuple[int, str, int] | None:
        """Return (HTTP code, Portuguese message, Retry-After) or None."""
        if self.strict and not self.tokens:
            return 503, "Autenticação do servidor não configurada.", 60
        if token and self.tokens and token not in self.tokens:
            return 403, "Acesso ao download não autorizado.", 0
        if self.strict and token not in self.tokens:
            return 403, "Token de acesso necessário.", 0
        identity = ("token:" + token) if token else ("ip:" + client_ip)
        key = hashlib.sha256(identity.encode()).hexdigest()[:24]
        moment = time.time() if now is None else now
        with self._lock:
            events = self._events.setdefault(key, deque())
            while events and events[0] <= moment - 86400:
                events.popleft()
            if len(events) >= self.per_day:
                return (429, "Limite diário de pedidos atingido. Tente amanhã.",
                        max(1, int(86400 - (moment - events[0]))))
            recent = sum(event > moment - 60 for event in events)
            if recent >= self.per_minute:
                return 429, "Muitos pedidos em pouco tempo. Aguarde e tente novamente.", 60
            events.append(moment)
            # No unbounded identity table after long uptime.
            if len(self._events) > 4096:
                for old_key in list(self._events)[:512]:
                    if old_key != key:
                        self._events.pop(old_key, None)
        return None
