import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


RUNNER = Path(__file__).resolve().parents[2] / "scripts/bench_keystroke_latency_ab"
MIX = r'''#!/usr/bin/env bash
set -euo pipefail
side=${PWD##*/}
case "$*" in
  deps.get) printf 'prepare %s\n' "$side" >> "$EVENTS" ;;
  codegen) ;;
  compile) git rev-parse HEAD > .prepared ;;
  'run --no-compile bench/keystroke_latency_baseline.exs')
    [[ $(cat .prepared) == "$(git rev-parse HEAD)" ]]
    printf 'sample %s\n' "$side" >> "$EVENTS"
    if [[ $MODE == missing-head && $side == head && ! -e .first-head ]]; then
      touch .first-head
    else
      printf '{"side":"%s"}\n' "$side" > bench/baselines/keystroke_latency.json
    fi ;;
  'run --no-compile bench/check_latency_budgets.exs '*)
    [[ $side == head && $4 == --comparison-output ]]
    output=$5
    shift 5
    printf 'check %s\n' "$(( $# / 2 ))" >> "$EVENTS"
    printf '{"samples":%s}\n' "$(( $# / 2 ))" > "$output"
    [[ $MODE != confirm || $# != 8 ]] ;;
  *) exit 91 ;;
esac
'''


class KeystrokeLatencyRunnerTest(unittest.TestCase):
    def run_comparison(self, mode):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / "source"
            source.mkdir()
            (source / "bench/baselines").mkdir(parents=True)
            (source / "bench/keystroke_latency_baseline.exs").touch()
            (source / "bench/baselines/keystroke_latency.json").write_text('{"stale":true}')
            self.git(source, "init", "-q")
            self.git(source, "add", "bench")
            self.git(source, "commit", "-qm", "base")
            self.git(source, "commit", "--allow-empty", "-qm", "head")
            binary = root / "bin"
            binary.mkdir()
            (binary / "mix").write_text(MIX)
            (binary / "mix").chmod(0o755)
            temp = root / "worktrees"
            temp.mkdir()
            events = root / "events"
            env = dict(os.environ, PATH=f"{binary}:{os.environ['PATH']}", TMPDIR=str(temp), GITHUB_WORKSPACE=str(root), EVENTS=str(events), MODE=mode, MINGA_LATENCY_AB_ROUNDS="2", MINGA_LATENCY_AB_CONFIRMATION_ROUNDS="2")
            result = subprocess.run(["bash", str(RUNNER), "HEAD^", "HEAD"], cwd=source, env=env, text=True, capture_output=True, timeout=30)
            self.assertEqual([], list(temp.iterdir()), result.stdout + result.stderr)
            comparison = root / "keystroke_latency_comparison.json"
            return result, events.read_text().splitlines(), json.loads(comparison.read_text()) if comparison.exists() else None

    @staticmethod
    def git(source, *args):
        subprocess.run(["git", "-c", "user.name=Benchmark test", "-c", "user.email=benchmark@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *args], cwd=source, check=True, capture_output=True, timeout=10)

    def test_missing_head_sample_fails_instead_of_passing_a_head_only_retry(self):
        result, events, comparison = self.run_comparison("missing-head")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Could not record head latency sample for round 1", result.stderr)
        self.assertEqual(["prepare head", "prepare base", "sample base", "sample head"], events)
        self.assertIsNone(comparison)

    def test_confirmation_reuses_each_build_and_preserves_order(self):
        result, events, comparison = self.run_comparison("confirm")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        pair = ["sample base", "sample head", "sample head", "sample base"]
        self.assertEqual(["prepare head", "prepare base", *pair, "check 4", *pair, "check 8"], events)
        self.assertEqual({"samples": 8}, comparison)


if __name__ == "__main__":
    unittest.main()
