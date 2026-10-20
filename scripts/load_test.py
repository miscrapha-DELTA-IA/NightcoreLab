"""Bounded 20-user download test. Start a backend separately before running.

Example: python scripts/load_test.py --base-url http://127.0.0.1:8000
Never prints signed R2 URLs or retains downloaded audio.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import math
from pathlib import Path
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen


def _json(url: str) -> dict:
    try:
        with urlopen(Request(url, headers={"User-Agent": "GnarlyLoadTest/1"}), timeout=20) as response:
            return json.load(response)
    except (HTTPError, URLError, TimeoutError, ValueError):
        return {}


def _one(endpoint: str) -> dict:
    started = time.monotonic()
    total = 0
    try:
        with urlopen(Request(endpoint, headers={"User-Agent": "GnarlyLoadTest/1"}), timeout=300) as response:
            while chunk := response.read(64 * 1024):
                total += len(chunk)
            return {"status": response.status, "seconds": round(time.monotonic() - started, 3),
                    "bytes": total,
                    "r2": (urlparse(response.geturl()).hostname or "").endswith(".r2.cloudflarestorage.com")}
    except HTTPError as error:
        error.read(1024)
        return {"status": error.code, "seconds": round(time.monotonic() - started, 3), "bytes": 0}
    except (URLError, TimeoutError) as error:
        return {"error": type(error).__name__, "seconds": round(time.monotonic() - started, 3), "bytes": 0}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:8000")
    parser.add_argument("--video-url", default="https://www.youtube.com/watch?v=jNQXAC9IVRw")
    parser.add_argument("--users", type=int, default=20)
    parser.add_argument("--peak", type=int, default=5)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not 1 <= args.users <= 100 or not 1 <= args.peak <= 10:
        parser.error("users deve estar entre 1-100 e peak entre 1-10")
    base = args.base_url.rstrip("/")
    before = _json(base + "/metrics")
    endpoint = base + "/download?" + urlencode({"url": args.video_url})
    started = time.monotonic()
    with ThreadPoolExecutor(max_workers=args.peak) as pool:
        futures = [pool.submit(_one, endpoint) for _ in range(args.users)]
        results = [future.result() for future in as_completed(futures)]
    after = _json(base + "/metrics")
    durations = sorted(result["seconds"] for result in results)
    failures = sum(result.get("status") != 200 for result in results)
    report = {"base_host": urlparse(base).hostname, "users": args.users, "peak": args.peak,
              "duration_seconds": round(time.monotonic() - started, 3),
              "p95_seconds": durations[math.ceil(0.95 * len(durations)) - 1],
              "error_rate": failures / len(results), "peak_rss_bytes": after.get("peak_rss_bytes"),
              "r2_hits_observed": sum(result.get("r2", False) for result in results),
              "bytes_received": sum(result["bytes"] for result in results),
              "metrics_before": before, "metrics_after": after,
              "status_counts": {str(code): sum(result.get("status") == code for result in results)
                                for code in sorted({result.get("status") for result in results}, key=str)}}
    report["targets_met"] = {"error_rate_under_2_percent": report["error_rate"] < 0.02,
                             "rss_under_400_mib": (report["peak_rss_bytes"] < 400 * 1024 * 1024
                                                   if report["peak_rss_bytes"] else None)}
    output = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output + "\n", encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()
