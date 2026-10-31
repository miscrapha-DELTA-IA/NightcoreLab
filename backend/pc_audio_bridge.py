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
LEASE_SECONDS = 210  # Windows extraction (75s) + upload (90s) + network headroom
STALE_SECONDS = 300
ONLINE_SECONDS = 25
FAILED_RETRY_SECONDS = 35


@dataclass
class Job:
    video_id: str
    created: float
    event: asyncio.Event = field(default_factory=asyncio.Event)
    state: str = "pending"
    leased_until: float = 0
    lease: str = ""
    reason: str = ""
    finished: float = 0.0


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
            if not self.configured():
                return False
            now = self._now()
            # A synchronous Windows worker does not poll while extracting.
            # Its accepted, unexpired lease is proof the node is still busy.
            # Never fall back to Render's known-blocked IP mid-job.
            return now - self._last_seen <= ONLINE_SECONDS or any(
                j.state == "leased" and j.leased_until > now
                for j in self._jobs.values()
            )

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
                if old.state in ("pending", "leased"):
                    return old
                # A failed lookup is not a five-minute permanent tombstone.
                # Preserve a bounded retry cooldown; one new explicit request
                # can start fresh work once the worker is available again.
                delay = FAILED_RETRY_SECONDS if old.state == "failed" else 5
                if self._now() - old.finished < delay:
                    return old
                self._jobs.pop(video_id, None)
            # Completed songs must not consume active queue capacity.
            # Otherwise the ninth distinct song in five minutes gets rejected.
            active = sum(j.state in ("pending", "leased") for j in self._jobs.values())
            if active >= MAX_JOBS:
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
                    job.finished = self._now()
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
            job.finished = self._now()
            # A successful upload/failure report is also a recent authentic
            # worker heartbeat. Avoid switching to Render IP in the instant
            # before the Windows agent resumes its normal next-job polling.
            self._last_seen = job.finished
            job.lease = ""
            job.event.set()
            return True

    def status(self, video_id: str) -> dict:
        if not _VIDEO_ID.fullmatch(video_id):
            return {"state": "invalid", "node_online": False}
        with self._lock:
            self._sweep()
            job = self._jobs.get(video_id)
            return {
                "state": job.state if job else "absent",
                "node_online": self.online(),
            }

    def snapshot(self) -> dict:
        with self._lock:
            self._sweep()
            return {"configured": self.configured(), "online": self.online(),
                    "pending": sum(j.state == "pending" for j in self._jobs.values()),
                    "leased": sum(j.state == "leased" for j in self._jobs.values()),
                    "ready": sum(j.state == "ready" for j in self._jobs.values())}


queue = AudioNodeQueue()
