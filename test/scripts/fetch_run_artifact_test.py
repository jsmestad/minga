#!/usr/bin/env python3
"""fetch-run-artifact waits out the artifacts API's brief 404 after upload and fails on anything else."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/fetch-run-artifact"
METADATA = "repos/owner/repo/actions/artifacts/42"
ZIP = "repos/owner/repo/actions/artifacts/42/zip"

# Stands in for `gh api ENDPOINT`. The first FAKE_GH_MISSES calls per endpoint answer like gh does for a missing artifact: an error body on stdout and FAKE_GH_MISS_STATUS on stderr.
FAKE_GH = r"""#!/usr/bin/env bash
set -euo pipefail
test "$1" = api
printf '%s\n' "$2" >> "$FAKE_GH_LOG"
if [ -n "${FAKE_GH_FAILURE:-}" ]; then
  printf '{"message":"refused"}'
  echo "gh: $FAKE_GH_FAILURE" >&2
  exit 1
fi
if [ "$(grep -cxF -- "$2" "$FAKE_GH_LOG")" -le "$FAKE_GH_MISSES" ]; then
  printf '{"message":"Not Found"}'
  echo "gh: ${FAKE_GH_MISS_STATUS:-Not Found (HTTP 404)}" >&2
  exit 1
fi
case "$2" in
  */zip) printf 'zip bytes' ;;
  *) printf '{"id":42}' ;;
esac
"""


class FetchRunArtifactTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        bin_dir = self.work / "bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text(FAKE_GH)
        (bin_dir / "gh").chmod(0o755)
        self.log = self.work / "gh.log"
        self.log.touch()
        self.environment = {
            **os.environ,
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "GITHUB_REPOSITORY": "owner/repo",
            "FAKE_GH_LOG": str(self.log),
            "FAKE_GH_MISSES": "0",
            "FETCH_RUN_ARTIFACT_DELAYS": "0 0 0",
        }
        self.metadata = self.work / "artifact.json"
        self.zip = self.work / "42.zip"

    def run_script(self, **environment):
        return subprocess.run([str(SCRIPT), "42", str(self.metadata), str(self.zip)],
                              env={**self.environment, **environment}, capture_output=True, text=True)

    def calls(self):
        return self.log.read_text().splitlines()

    def leftovers(self):
        return sorted(path.name for path in self.work.iterdir() if path.name not in ("bin", "gh.log"))

    def test_retries_a_fresh_artifact_until_the_api_serves_it(self):
        result = self.run_script(FAKE_GH_MISSES="2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.metadata.read_text(), '{"id":42}')
        self.assertEqual(self.zip.read_text(), "zip bytes")
        self.assertEqual(self.calls(), [METADATA] * 3 + [ZIP] * 3)
        self.assertEqual(self.leftovers(), ["42.zip", "artifact.json"])
        self.assertIn("HTTP 404 on attempt 2", result.stderr)

    def test_retries_the_bare_404_that_gh_reports_for_the_zip_redirect(self):
        result = self.run_script(FAKE_GH_MISSES="1", FAKE_GH_MISS_STATUS="HTTP 404")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [METADATA] * 2 + [ZIP] * 2)
        self.assertEqual(self.zip.read_text(), "zip bytes")

    def test_gives_up_after_the_bounded_attempts_without_writing_the_error_body(self):
        result = self.run_script(FAKE_GH_MISSES="100")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [METADATA] * 4)
        self.assertIn(f"GET {METADATA} still returned HTTP 404 after 4 attempts", result.stderr)
        self.assertEqual(self.leftovers(), [])

    def test_fails_at_once_on_any_other_error(self):
        result = self.run_script(FAKE_GH_FAILURE="Forbidden (HTTP 403)")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [METADATA])
        self.assertIn("gh: Forbidden (HTTP 403)", result.stderr)
        self.assertIn("not retrying", result.stderr)
        self.assertEqual(self.leftovers(), [])


if __name__ == "__main__":
    unittest.main()
