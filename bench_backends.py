#!/usr/bin/env python3
"""
Benchmark MLX vs Ollama backends for netmon.
Measures: first-token latency, total latency, tokens/s for
  1. Simple text completion
  2. Tool-call round-trip (one tool call + result)
"""
import json
import sys
import time
import urllib.request
from pathlib import Path
from statistics import mean, stdev

sys.path.insert(0, str(Path(__file__).parent))
import analyze

RUNS = 5

SIMPLE_PROMPT = [
    {"role": "user", "content": "In one sentence, what is a network anomaly?"}
]

TOOL_PROMPT = [
    {"role": "user", "content": (
        "Process 'curl' connected to 1.2.3.4:443. "
        "Please call mark_as_normal for this event. "
        "Event process=curl, remote=1.2.3.4:443."
    )}
]

TOOLS = [t for t in analyze.TOOLS if t["function"]["name"] in ("mark_as_normal", "send_notification")]


def time_call(fn, *args, **kwargs):
    t0 = time.perf_counter()
    result = fn(*args, **kwargs)
    return time.perf_counter() - t0, result


def bench_backend(backend: str, model: str, label: str):
    from unittest.mock import patch

    print(f"\n{'='*60}")
    print(f"  {label}  ({model})")
    print(f"{'='*60}")

    def cfg():
        return {"backend": backend, "mlx_model": "mlx-community/Qwen3-4B-4bit",
                "llm_model": model}

    # ── Simple completion ──────────────────────────────────────────────────
    simple_times = []
    for i in range(RUNS):
        with patch("analyze.read_config", cfg):
            elapsed, resp = time_call(analyze.chat, SIMPLE_PROMPT[:], None, 60, model)
        content = (resp or {}).get("message", {}).get("content", "")
        simple_times.append(elapsed)
        print(f"  [simple #{i+1}] {elapsed:.2f}s  → {content[:60]!r}")

    print(f"  ▸ simple latency: mean={mean(simple_times):.2f}s  "
          f"sd={stdev(simple_times) if len(simple_times) > 1 else 0:.2f}s  "
          f"min={min(simple_times):.2f}s  max={max(simple_times):.2f}s")

    # ── Tool-call round-trip ───────────────────────────────────────────────
    tool_times = []
    for i in range(RUNS):
        messages = TOOL_PROMPT[:]
        t0 = time.perf_counter()
        with patch("analyze.read_config", cfg), \
             patch("analyze.dispatch", return_value="marked as normal"), \
             patch("analyze.check_injection", return_value=False):
            result = analyze.run_with_tools(messages)
        elapsed = time.perf_counter() - t0
        tool_times.append(elapsed)
        tool_calls_used = len([m for m in messages if m.get("role") == "tool"])
        print(f"  [tool  #{i+1}] {elapsed:.2f}s  tool_calls={tool_calls_used}  result={result[:50]!r}")

    print(f"  ▸ tool latency:   mean={mean(tool_times):.2f}s  "
          f"sd={stdev(tool_times) if len(tool_times) > 1 else 0:.2f}s  "
          f"min={min(tool_times):.2f}s  max={max(tool_times):.2f}s")

    return {
        "label": label,
        "simple_mean": mean(simple_times),
        "simple_min":  min(simple_times),
        "tool_mean":   mean(tool_times),
        "tool_min":    min(tool_times),
    }


if __name__ == "__main__":
    results = []

    # MLX: Qwen3-4B-4bit
    results.append(bench_backend("mlx", "mlx-community/Qwen3-4B-4bit", "MLX  Qwen3-4B-4bit"))

    # Ollama: granite4.1:3b (current default)
    results.append(bench_backend("ollama", "granite4.1:3b", "Ollama granite4.1:3b"))

    # Ollama: qwen3.5:2b (smaller, may be faster)
    results.append(bench_backend("ollama", "qwen3.5:2b", "Ollama qwen3.5:2b"))

    print(f"\n{'='*60}")
    print("  SUMMARY")
    print(f"{'='*60}")
    print(f"  {'Backend':<30} {'Simple(mean)':>14} {'Tool(mean)':>12}")
    print(f"  {'-'*30} {'-'*14} {'-'*12}")
    for r in results:
        print(f"  {r['label']:<30} {r['simple_mean']:>13.2f}s {r['tool_mean']:>11.2f}s")
    print()
