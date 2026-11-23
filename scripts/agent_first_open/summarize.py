#!/usr/bin/env python3
"""Summarize a measure.py output directory into the tables used by bench/agent_first_open.md.

Usage: summarize.py OUTPUT_DIR [OUTPUT_DIR...]

Percentiles are nearest-rank over the raw samples in samples.ndjson.
"""

import json
import math
from pathlib import Path
import sys

ENDPOINTS = ("composer_emit_ms", "composer_presented_ms", "send_ready_ms")
CONDITIONS = ("immediate", "later-first", "later-same-run")
STAGES = (
    "catalog_load",
    "tab_switch",
    "start_agent_session",
    "ensure_configured_model",
    "project_view_overlay",
    "session_manager_start",
    "session_init",
    "session_model_resolve",
    "session_subscribe",
    "provider_project_view_refresh",
    "session_snapshot_read",
    "provider_start",
    "session_start_hooks",
    "session_start_hook_config",
)


def rank(values, p):
    values = sorted(values)
    return values[math.ceil(len(values) * p / 100) - 1] if values else None


def fmt(value):
    return "n/a" if value is None else f"{value:,.1f}"


def stage_total(sample, stage):
    spans = sample["stages"].get(stage)
    return sum(span["duration_ms"] for span in spans) if spans else None


def overlap(a_start, a_end, b_start, b_end):
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def provider_wait(sample):
    """Milliseconds of the Editor's subscribe call spent while the session ran its provider start and hooks."""
    subscribe = sample["stages"].get("session_subscribe")
    provider = sample["stages"].get("provider_start")
    if not subscribe or not provider:
        return None
    hooks = sample["stages"].get("session_start_hooks") or provider
    start = provider[0]["start_ms"]
    end = hooks[-1]["start_ms"] + hooks[-1]["duration_ms"]
    call = subscribe[0]
    return overlap(call["start_ms"], call["start_ms"] + call["duration_ms"], start, end)


def main():
    samples = []
    for directory in sys.argv[1:]:
        for line in (Path(directory) / "samples.ndjson").read_text(encoding="utf-8").splitlines():
            samples.append(json.loads(line))
    opens = [s for s in samples if s["condition"] != "launch"]
    launches = [s for s in samples if s["condition"] == "launch"]

    print("## Endpoints (ms from the final key-down post)\n")
    print("| Command | Condition | n | Composer frame written (BEAM) p50 / p95 | Composer frame presented (app) p50 / p95 | Send-ready frame written (BEAM) p50 / p95 |")
    print("|---|---|---:|---|---|---|")
    for command in ("n", "a"):
        for condition in CONDITIONS:
            cell = [s for s in opens if s["command"] == command and s["condition"] == condition]
            if not cell:
                continue
            values = []
            for endpoint in ENDPOINTS:
                v = [s[endpoint] for s in cell if s.get(endpoint) is not None]
                values.append(f"{fmt(rank(v, 50))} / {fmt(rank(v, 95))}" + ("" if len(v) == len(cell) else f" (n={len(v)})"))
            print(f"| SPC a {command} | {condition} | {len(cell)} | " + " | ".join(values) + " |")

    print("\n## Stages (ms, p50 / p95 per open)\n")
    header = [f"SPC a {c} {cond}" for c in ("n", "a") for cond in CONDITIONS]
    print("| Stage | " + " | ".join(header) + " |")
    print("|---|" + "---|" * len(header))
    derived = {
        "frontend: presented minus written": lambda s: (s["composer_presented_ms"] - s["composer_emit_ms"]) if s.get("composer_presented_ms") is not None else None,
        "key post to BEAM dispatch": lambda s: s["final_key_dispatch_ms"],
        "subscribe time behind provider start and hooks": provider_wait,
    }
    rows = [(stage, (lambda st: lambda s: stage_total(s, st))(stage)) for stage in STAGES] + list(derived.items())
    for name, getter in rows:
        cells = []
        for command in ("n", "a"):
            for condition in CONDITIONS:
                v = [x for x in (getter(s) for s in opens if s["command"] == command and s["condition"] == condition) if x is not None]
                cells.append(f"{fmt(rank(v, 50))} / {fmt(rank(v, 95))}" if v else "")
        print(f"| {name} | " + " | ".join(cells) + " |")

    catalog_share = [stage_total(s, "catalog_load") / s["composer_emit_ms"] for s in opens if stage_total(s, "catalog_load")]
    if catalog_share:
        print(f"\nCatalog load share of the composer frame write, cold opens: p50 {rank(catalog_share, 50):.1%}, min {min(catalog_share):.1%}, max {max(catalog_share):.1%} (n={len(catalog_share)})")
    first = [s["first_presented_ms"] for s in launches]
    if first:
        print(f"Launch to first presented frame: p50 {fmt(rank(first, 50))} ms, p95 {fmt(rank(first, 95))} ms (n={len(first)})")


if __name__ == "__main__":
    main()
