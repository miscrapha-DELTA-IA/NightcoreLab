"""Bounded, anonymous streaming observability. No track IDs, URLs or IPs.

Histograms are process-local and reset when Render restarts. Nothing is logged
per listener, and this module never controls audio routing or timeouts.
"""
from collections import Counter, deque
from threading import RLock
from time import monotonic

EVENTS = frozenset({
    "first_audio", "recovered_audio", "initial_media_error",
    "final_error", "watchdog", "play_cancelled"
})
SOURCES = frozenset({"fast_edge", "render", "offline", "independent", "unknown"})
ROUTES = frozenset({"/stream", "/download", "/prepare", "/pc-node/prepare",
                    "/pc-node/status", "/pc-node/upload"})
_MAX_CLIENT_PER_MINUTE = 180
_MAX_MS = 240000
_BUCKETS_MS = (250, 1000, 3000, 8000, 15000, 25000, 35000, 60000, 120000, 240000)


def _percentile(points, percentage):
    if not points:
        return None
    ordered = sorted(points)
    index = max(0, min(len(ordered) - 1, (len(ordered) * percentage + 99) // 100 - 1))
    return ordered[index]


class StreamingMetrics:
    def __init__(self, now=monotonic):
        self._now = now
        self._lock = RLock()
        self._browser = Counter()
        self._server = Counter()
        self._timings = {}
        self._minute = now()
        self._minute_count = 0
        self._dropped = 0

    @staticmethod
    def _elapsed(value):
        # bool and NaN are not measurements.
        if type(value) not in (float, int) or not 0 <= value <= _MAX_MS:
            raise ValueError("Invalid latency")
        return round(value)

    def client(self, payload):
        if not isinstance(payload, dict) or set(payload) != {"event", "source", "ms", "code"}:
            raise ValueError("Invalid metric fields")
        event, source = payload["event"], payload["source"]
        if event not in EVENTS or source not in SOURCES:
            raise ValueError("Invalid metric category")
        ms = self._elapsed(payload["ms"])
        code = payload["code"]
        if type(code) is not int or code not in (0, 2, 3, 4):
            raise ValueError("Invalid media code")
        with self._lock:
            now = self._now()
            if now - self._minute >= 60:
                self._minute = now
                self._minute_count = 0
            if self._minute_count >= _MAX_CLIENT_PER_MINUTE:
                self._dropped += 1
                return False
            self._minute_count += 1
            key = (event, source)
            self._browser[key] += 1
            self._timings.setdefault(("browser",) + key, deque(maxlen=256)).append(ms)
        return True

    def server(self, route, status, elapsed_ms):
        if route not in ROUTES:
            return
        ms = self._elapsed(elapsed_ms)
        status_class = f"{int(status) // 100}xx"
        if status_class not in ("2xx", "3xx", "4xx", "5xx"):
            return
        # collapse dynamic /pc-node URLs to fixed route, never retain IDs
        key = (route, status_class)
        with self._lock:
            self._server[key] += 1
            self._timings.setdefault(("server",) + key, deque(maxlen=256)).append(ms)

    def snapshot(self):
        with self._lock:
            def entries(counter, kind):
                result = {}
                for key, count in counter.items():
                    samples = self._timings.get((kind,) + key, ())
                    name = "/".join(key)
                    result[name] = {
                        "count": count,
                        "p50_ms": _percentile(samples, 50),
                        "p95_ms": _percentile(samples, 95),
                        "over_30s": sum(x >= 30000 for x in samples),
                    }
                return result
            return {
                "client": entries(self._browser, "browser"),
                "backend_headers": entries(self._server, "server"),
                "client_dropped": self._dropped,
                "latency_window": 256,
                "scope": "process_local",
            }


streaming_metrics = StreamingMetrics()
