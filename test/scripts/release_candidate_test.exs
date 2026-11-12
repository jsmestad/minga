defmodule Minga.Scripts.ReleaseCandidateTest do
  # System.cmd opens a real OS port for the Python verifier suite; serialize it against other subprocess tests.
  use ExUnit.Case, async: false

  @tag timeout: 60_000
  test "rejects changed bytes, provenance, generations and unsafe artifact archives" do
    script = Path.join(__DIR__, "release_candidate_test.py")
    {output, status} = System.cmd("python3", ["-B", script], stderr_to_stdout: true)
    assert status == 0, output
  end
end
