"""Measure Gnarly's HTTP download contract without retaining remote media.

Examples:
    python scripts/bench_backend.py --base-url https://nightcorelab.onrender.com
    python scripts/bench_backend.py --launch-local --health-only

The local mode samples Linux /proc for process RSS and CPU. Remote Render CPU/RSS
must be read from Render metrics for the same time window; HTTP cannot expose a
trustworthy container peak before the proposed /metrics endpoint exists.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_THREE_MINUTE = "https://www.youtube.com/watch?v=3Jl2nryJ944"
# yt-dlp's public test fixture is 597 seconds, the nearest stable case below
# the backend's strict 600-second limit. A >=600-second file should return 413.
DEFAULT_NEAR_TEN_MINUTE = "https://www.youtube.com/watch?v=YE7VzlLtp-4"


def _sample_proc(pid: int, stop: threading.Event, result: dict) -> None:
    if not Path(f"/proc/{pid}").exists():
        return
    ticks = os.sysconf("SC_CLK_TCK")
    first_cpu = None
    first_time = time.monotonic()
    while not stop.wait(0.1):
        try:
            status = Path(f"/proc/{pid}/status").read_text()
            fields = Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].split()
            cpu = (int(fields[11]) + int(fields[12])) / ticks
            rss_kib = int(next(line.split()[1] for line in status.splitlines()
                               if line.startswith("VmRSS:")))
            result["peak_process_rss_bytes"] = max(result.get("peak_process_rss_bytes", 0), rss_kib * 1024)
            if first_cpu is None:
                first_cpu = cpu
            result["process_cpu_seconds"] = max(0, cpu - first_cpu)
            result["sample_duration_seconds"] = time.monotonic() - first_time
        except (OSError, ValueError, StopIteration):
            break


def _request(base: str, path: str, timeout: float) -> dict:
    started = time.monotonic()
    size = 0
    try:
        with urlopen(Request(base.rstrip("/") + path, headers={"User-Agent": "GnarlyBackendBench/1"}),
                     timeout=timeout) as response:
            first = response.read(1)
            ttfb = time.monotonic() - started
            size += len(first)
            while chunk := response.read(64 * 1024):
                size += len(chunk)
            host = urlparse(response.geturl()).hostname or ""
            return {"status": response.status, "ttfb_seconds": round(ttfb, 3),
                    "total_seconds": round(time.monotonic() - started, 3),
                    "bytes_received": size,
                    "r2_redirect_followed": host.endswith(".r2.cloudflarestorage.com")}
    except HTTPError as error:
        # Read a bounded error body to release the connection, never log URLs.
        error.read(4096)
        return {"status": error.code, "ttfb_seconds": round(time.monotonic() - started, 3),
                "total_seconds": round(time.monotonic() - started, 3), "bytes_received": 0}
    except (URLError, TimeoutError) as error:
        return {"error": type(error).__name__,
                "total_seconds": round(time.monotonic() - started, 3), "bytes_received": 0}


def _launch_local() -> tuple[subprocess.Popen, str, float]:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    started = time.monotonic()
    process = subprocess.Popen([sys.executable, "-m", "uvicorn", "main:app", "--host",
                                "127.0.0.1", "--port", str(port)], cwd=ROOT / "backend",
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    while time.monotonic() - started < 90 and process.poll() is None:
        try:
            with urlopen(base + "/health", timeout=1) as response:
                if response.status == 200:
                    return process, base, time.monotonic() - started
        except (HTTPError, URLError, TimeoutError):
            try:
                with urlopen(base + "/", timeout=1) as response:
                    if response.status == 200:
                        return process, base, time.monotonic() - started
            except (HTTPError, URLError, TimeoutError):
                pass
        time.sleep(0.1)
    process.terminate()
    raise RuntimeError("O servidor local não ficou pronto em 90 segundos")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="https://nightcorelab.onrender.com")
    parser.add_argument("--launch-local", action="store_true")
    parser.add_argument("--health-only", action="store_true")
    parser.add_argument("--three-minute-url", default=DEFAULT_THREE_MINUTE)
    parser.add_argument("--near-ten-minute-url", default=DEFAULT_NEAR_TEN_MINUTE)
    parser.add_argument("--pid", type=int, help="Linux server PID for process-only RSS/CPU sampling")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    process = None
    base = args.base_url
    report = {"base_host": urlparse(base).hostname, "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
              "measurement_scope": "HTTP client; optional process-only /proc sampling"}
    if args.launch_local:
        process, base, report["cold_boot_to_health_seconds"] = _launch_local()
        report["base_host"] = "127.0.0.1"
    stats: dict = {}
    stop = threading.Event()
    sampler = threading.Thread(target=_sample_proc, args=(args.pid or process.pid, stop, stats), daemon=True) if args.pid or process else None
    if sampler:
        sampler.start()
    try:
        report["health"] = _request(base, "/health", 90)
        if report["health"].get("status") == 404:
            report["health"] = _request(base, "/", 90)
        if not args.health_only:
            report["cases"] = {
                "three_minute": _request(base, "/download?" + urlencode({"url": args.three_minute_url}), 300),
                "near_ten_minute_597s": _request(base, "/download?" + urlencode({"url": args.near_ten_minute_url}), 300),
                "invalid_host": _request(base, "/download?" + urlencode({"url": "https://example.com/video"}), 90),
            }
    finally:
        stop.set()
        if sampler:
            sampler.join(timeout=1)
        if process:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
    report["process_sample"] = stats or None
    output = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output + "\n", encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()
