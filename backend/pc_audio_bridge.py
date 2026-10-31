"""Bounded, outbound-only Windows audio node queue.

No inbound connection to the PC, no arbitrary URLs, no proxying user traffic.
The node polls the existing Render API over TLS, extracts only canonical IDs,
and uploads exact M4A bytes via an authenticated endpoint. The server then
publishes the validated file to its existing R2 cache.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import asyncio
import hmac
import os
import secrets
import threading
import time

_VIDEO_ID = __import__("re").compile(r"^[A-Za-z0-9_-]{11}$")
MAX_JOBS = 8
LEASE_SECONDS = 100
STALE_SECONDS = 300
ONLINE_SECONDS = 25


@dataclass
class Job:
    video_id: str
    created: float
    event: asyncio.Event = field(default_factory=asyncio.Event)
    state: str = "pending"
    leased_until: float = 0
    lease: str = ""
    reason: str = ""


class AudioNodeQueue:
    def __init__(self, *, now=time.monotonic):
        self._now = now
        self._lock = threading.RLock()
        self._jobs: dict[str, Job] = {}
        self._last_seen = float("-inf")

    @staticmethod
    def configured() -> bool:
        return len(os.getenv("GNARLY_PC_NODE_TOKEN", "")) >= 40

    @staticmethod
    def authorized(header: str | None) -> bool:
        expected = os.getenv("GNARLY_PC_NODE_TOKEN", "")
        if len(expected) < 40:
            return False
        provided = header.removeprefix("Bearer ").strip() if header else ""
        return hmac.compare_digest(provided, expected)

    def online(self) -> bool:
        with self._lock:
            return self.configured() and self._now() - self._last_seen <= ONLINE_SECONDS

    def heartbeat(self) -> None:
        with self._lock:
            self._last_seen = self._now()

    def _sweep(self) -> None:
        now = self._now()
        for key, job in list(self._jobs.items()):
            if now - job.created >= STALE_SECONDS:
                if not job.event.is_set():
                    job.state = "failed"
                    job.event.set()
                self._jobs.pop(key, None)

    def request(self, video_id: str) -> Job | None:
        if not _VIDEO_ID.fullmatch(video_id) or not self.online():
            return None
        with self._lock:
            self._sweep()
            old = self._jobs.get(video_id)
            if old:
                return old
            if len(self._jobs) >= MAX_JOBS:
                return None
            job = Job(video_id=video_id, created=self._now())
            self._jobs[video_id] = job
            return job

    async def wait(self, video_id: str, timeout: float = 12) -> str | None:
        job = self.request(video_id)
        if not job:
            return None
        try:
            await asyncio.wait_for(job.event.wait(), timeout=timeout)
        except asyncio.TimeoutError:
            return "pending"
        return job.state

    def lease_next(self) -> tuple[str, str] | None:
        with self._lock:
            self.heartbeat()
            self._sweep()
            for job in self._jobs.values():
                if job.state == "leased" and job.leased_until <= self._now():
                    job.state = "failed"
                    job.reason = "lease_expired"
                    job.event.set()
                if job.state != "pending":
                    continue
                job.state = "leased"
                job.lease = secrets.token_urlsafe(32)
                job.leased_until = self._now() + LEASE_SECONDS
                return job.video_id, job.lease
            return None

    def validate_lease(self, video_id: str, lease: str) -> bool:
        with self._lock:
            job = self._jobs.get(video_id)
            return (job is not None and job.state == "leased"
                    and job.leased_until > self._now()
                    and bool(lease) and hmac.compare_digest(job.lease, lease))

    def finish(self, video_id: str, lease: str, *, success: bool, reason: str = "") -> bool:
        with self._lock:
            if not self.validate_lease(video_id, lease):
                return False
            job = self._jobs[video_id]
            job.state = "ready" if success else "failed"
            job.reason = reason[:40]
            job.lease = ""
            job.event.set()
            return True

    def snapshot(self) -> dict:
        with self._lock:
            self._sweep()
            return {"configured": self.configured(), "online": self.online(),
                    "pending": sum(j.state == "pending" for j in self._jobs.values()),
                    "leased": sum(j.state == "leased" for j in self._jobs.values()),
                    "ready": sum(j.state == "ready" for j in self._jobs.values())}


queue = AudioNodeQueue()
