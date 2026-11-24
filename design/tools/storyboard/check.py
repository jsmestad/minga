"""Flow-map checker for docs/design/scenarios.toml.

Usage: python3 design/tools/storyboard/check.py [--final] [path/to/scenarios.toml]

Reports design gaps in the storyboard inventory:

  1. exits whose target scenario does not exist
  2. scenarios unreachable from the cold-start scenario by keys, and by clicks
  3. dead ends: scenarios that cannot reach a home scenario within 3 presses of esc or q
     (or an exit marked back = true)
  4. list surfaces without an empty-state scenario
  5. transient surfaces with an exit that has a key but no click, or a click but no key,
     unless the exit sets keyboard_only with a reason

Mouse paths are designed in a sweep after the keyboard design (see storyboard.md).
While scenarios.toml sets phase = "keyboard", missing click paths (2, by clicks,
and 5) are reported as "pending mouse sweep" and do not fail the run. With
--final, or phase = "final", they are violations like the rest.

Deferred scenarios (needs a rethink before design) are listed like missing ones
for reporting and are not violations by themselves. Removed scenarios are skipped, and so are states that are not places (no exits),
terminal states and surfaces outside the app. Scenarios with reached_by (events
such as errors or Minga asking) count as reachable, and a list reaches its
empty_state the same way it is reached. Exits with exit code 1 when any violation is found.
Standard library only (Python 3.11+).
"""
import sys
import tomllib
from collections import deque
from pathlib import Path

DEFAULT = Path(__file__).resolve().parents[3] / "docs" / "design" / "scenarios.toml"
BACK_KEYS = {"esc", "q"}


def load(path):
    with open(path, "rb") as f:
        data = tomllib.load(f)
    return data["scenario"], data.get("phase", "final")


def is_back(exit_):
    if exit_.get("back"):
        return True
    key = exit_.get("key", "").strip()
    return key in BACK_KEYS or key.startswith("esc ") or key.startswith("q ")


def reach(starts, edges):
    seen, todo = set(starts), deque(starts)
    while todo:
        cur = todo.popleft()
        for nxt in edges.get(cur, ()):
            if nxt not in seen:
                seen.add(nxt)
                todo.append(nxt)
    return seen


def check(scenarios):
    by_id = {s["id"]: s for s in scenarios}
    live = [s for s in scenarios if s.get("status") != "removed"]
    problems = {k: [] for k in ("unknown_target", "unreachable_by_key", "unreachable_by_click", "dead_end", "no_empty_state", "parity", "no_click")}

    for s in live:
        for e in s.get("exits", []):
            if e["to"] not in by_id:
                problems["unknown_target"].append(f"{s['id']} -> {e['to']}")

    key_edges, click_edges = {}, {}
    for s in live:
        for e in s.get("exits", []):
            if e["to"] not in by_id:
                continue
            if e.get("key", "").strip():
                key_edges.setdefault(s["id"], []).append(e["to"])
            if e.get("click", "").strip():
                click_edges.setdefault(s["id"], []).append(e["to"])
        # A list reaches its empty state the same way it is reached itself.
        if s.get("empty_state") in by_id:
            key_edges.setdefault(s["id"], []).append(s["empty_state"])
            click_edges.setdefault(s["id"], []).append(s["empty_state"])

    starts = [s["id"] for s in live if s.get("cold_start")]
    if len(starts) != 1:
        problems["unreachable_by_key"].append(f"expected exactly one cold_start scenario, found {starts}")
    else:
        # Scenarios that happen to you (reached_by an event) are reachable roots.
        roots = starts + [s["id"] for s in live if s.get("reached_by")]
        by_key, by_click = reach(roots, key_edges), reach(roots, click_edges)
        for s in live:
            if not s.get("exits") and not s.get("terminal_state"):
                continue  # a state, not a place (focus lost, narrow window, notifications)
            if s["id"] not in by_key:
                problems["unreachable_by_key"].append(s["id"])
            if s["id"] not in by_click:
                problems["unreachable_by_click"].append(s["id"])

    homes = {s["id"] for s in live if s.get("home")}
    back_edges = {}
    for s in live:
        back_edges[s["id"]] = [e["to"] for e in s.get("exits", []) if is_back(e) and e["to"] in by_id]
    for s in live:
        if s["id"] in homes or s.get("terminal_state") or s.get("outside_app") or not s.get("exits"):
            continue
        frontier, ok = {s["id"]}, False
        for _ in range(3):
            frontier = {n for cur in frontier for n in back_edges.get(cur, ())}
            if frontier & homes:
                ok = True
                break
        if not ok:
            problems["dead_end"].append(s["id"])

    for s in live:
        if s.get("list"):
            target = s.get("empty_state")
            if not target:
                problems["no_empty_state"].append(f"{s['id']} (no empty_state)")
            elif target not in by_id:
                problems["no_empty_state"].append(f"{s['id']} -> {target} (unknown)")

    for s in live:
        if not s.get("transient"):
            continue
        for e in s.get("exits", []):
            key, click = e.get("key", "").strip(), e.get("click", "").strip()
            if e.get("keyboard_only"):
                continue
            if key and not click:
                problems["no_click"].append(f"{s['id']}: '{key}' has no click")
            elif click and not key:
                problems["parity"].append(f"{s['id']}: '{click}' has no key")
    return problems


def main(argv):
    args = argv[1:]
    final_flag = "--final" in args
    args = [a for a in args if a != "--final"]
    path = Path(args[0]) if args else DEFAULT
    scenarios, phase = load(path)
    final = final_flag or phase == "final"
    problems = check(scenarios)
    counts = {}
    for s in scenarios:
        counts[s["status"]] = counts.get(s["status"], 0) + 1
    print(f"{len(scenarios)} scenarios: " + ", ".join(f"{v} {k}" for k, v in sorted(counts.items())))
    print(f"Phase: {'final' if final else phase} (mouse paths {'are checked' if final else 'pending the mouse sweep'})")
    labels = {
        "unknown_target": "Exits to unknown scenarios",
        "unreachable_by_key": "Unreachable from cold start by keys",
        "unreachable_by_click": "Unreachable from cold start by clicks",
        "dead_end": "Dead ends (no esc or q path home within 3 steps)",
        "no_empty_state": "Lists without an empty state",
        "parity": "Transient exits with a click but no key",
        "no_click": "Transient exits with a key but no click",
    }
    mouse = {"unreachable_by_click", "no_click"}
    total, pending = 0, 0
    for k, label in labels.items():
        items = problems[k]
        if k in mouse and not final:
            pending += len(items)
            label = f"{label} (pending mouse sweep)"
        else:
            total += len(items)
        print(f"\n{label}: {len(items)}")
        for item in items:
            print(f"  - {item}")
    if pending:
        print(f"\n{pending} pending the mouse sweep (not failures in the keyboard phase)")
    deferred = [s["id"] for s in scenarios if s["status"] == "deferred"]
    if deferred:
        print(f"\nDeferred (needs a rethink, not a violation): {len(deferred)}")
        for d in deferred:
            print(f"  - {d}")
    print(f"\n{total} violations")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
