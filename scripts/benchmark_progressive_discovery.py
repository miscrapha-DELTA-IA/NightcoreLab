"""Deterministic metadata contention benchmark, not live provider performance.
Run: python scripts/benchmark_progressive_discovery.py
"""
import asyncio
import json
from pathlib import Path
import statistics
import sys
import threading
import time
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from fast_stream import ProgressiveDiscovery

async def run(shared):
    gate=threading.BoundedSemaphore(2)
    calls=0
    def load():
        nonlocal calls
        with gate:
            calls+=1
            time.sleep(.04)  # Explicit synthetic metadata cost.
            return object()
    cache=ProgressiveDiscovery()
    async def request():
        start=time.perf_counter()
        if shared:await cache.get('same-recording',load)
        else:await asyncio.to_thread(load)
        return (time.perf_counter()-start)*1000
    results=sorted(await asyncio.gather(*[request() for _ in range(20)]))
    return {'requests':20,'metadata_calls':calls,'p50_ms':round(statistics.median(results),1),
            'p95_ms':round(results[18],1),'p99_ms':round(results[19],1)}

async def main():
    print(json.dumps({'fixture':'20 simultaneous requests; 40ms metadata; two worker slots; no network',
      'before':await run(False),'after':await run(True)},indent=2))

if __name__=='__main__':asyncio.run(main())
