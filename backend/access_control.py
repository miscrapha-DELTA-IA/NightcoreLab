"""Bounded per-client admission and short-lived download tickets for beta invites."""

from __future__ import annotations

from collections import deque
import hashlib
import hmac
import os
import secrets
import threading
import time


TICKET_TTL_SECONDS = 180


class AccessControl:
    def __init__(self, env: dict[str, str] | None = None):
        env = os.environ if env is None else env
        self.tokens = tuple(token.strip() for token in env.get("GNARLY_ACCESS_TOKENS", "").split(",")
                            if token.strip())
        # Existing public beta builds continue working until an operator configures
        # an allowlist. With an allowlist, auth defaults to strict (fail-closed).
        mode = env.get("GNARLY_AUTH_MODE", "").strip().lower()
        self.strict = mode == "strict" or (not mode and bool(self.tokens))
        self.per_minute = max(1, int(env.get("GNARLY_REQUESTS_PER_MINUTE", "120")))
        self.per_day = max(1, int(env.get("GNARLY_REQUESTS_PER_DAY", "500")))
        self._events: dict[str, deque[float]] = {}
        self._tickets: dict[str, tuple[str, float]] = {}
        self._lock = threading.Lock()

    def _valid_token(self, token: str | None) -> bool:
        # Check every candidate, without an early exit at a matching prefix/index.
        valid = False
        for candidate in self.tokens:
            valid |= hmac.compare_digest(token or "", candidate)
        return valid

    def _throttle(self, client_ip: str, moment: float) -> tuple[int, str, int] | None:
        # Never use client-controlled token text as a rate-limit key.
        key = hashlib.sha256(("ip:" + client_ip).encode()).hexdigest()[:24]
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
            if len(self._events) > 4096:
                for old_key in list(self._events)[:512]:
                    if old_key != key:
                        self._events.pop(old_key, None)
        return None

    def check(self, token: str | None, client_ip: str,
              now: float | None = None) -> tuple[int, str, int] | None:
        """Return (HTTP status, Portuguese explanation, Retry-After) or None."""
        if self.strict and not self.tokens:
            return 503, "Autenticação do servidor não configurada.", 60
        authorized = self._valid_token(token)
        if token and self.tokens and not authorized:
            return 403, "Acesso ao download não autorizado.", 0
        if self.strict and not authorized:
            return 403, "Token de acesso necessário.", 0
        return self._throttle(client_ip, time.time() if now is None else now)

    def issue_ticket(self, token: str | None, client_ip: str, video_id: str,
                     now: float | None = None) -> tuple[str | None, tuple[int, str, int] | None]:
        """Issue a single-use opaque capability for a *single* validated video ID."""
        moment = time.time() if now is None else now
        failure = self.check(token, client_ip, now=moment)
        if failure:
            return None, failure
        ticket = secrets.token_urlsafe(32)
        digest = hashlib.sha256(ticket.encode()).hexdigest()
        with self._lock:
            for key, (_, expiry) in list(self._tickets.items()):
                if expiry <= moment:
                    self._tickets.pop(key, None)
            if len(self._tickets) >= 2048:
                self._tickets.pop(next(iter(self._tickets)))
            self._tickets[digest] = (video_id, moment + TICKET_TTL_SECONDS)
        return ticket, None

    def check_ticket(self, ticket: str, client_ip: str, video_id: str,
                     now: float | None = None) -> tuple[int, str, int] | None:
        moment = time.time() if now is None else now
        digest = hashlib.sha256(ticket.encode()).hexdigest()
        with self._lock:
            saved = self._tickets.pop(digest, None)
        if not saved or saved[0] != video_id or saved[1] <= moment:
            return 403, "Autorização de download expirada. Tente novamente.", 0
        return self._throttle(client_ip, moment)
