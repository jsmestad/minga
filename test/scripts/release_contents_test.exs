defmodule Minga.Scripts.ReleaseContentsTest do
  # System.cmd opens a real OS port for the Python CLI suite; keep it out of the async pool.
  use ExUnit.Case, async: false

  @tag timeout: 60_000
  test "rejects incomplete, wrong-target and unsafe packaged contents" do
    script = Path.join(__DIR__, "release_contents_test.py")
    assert {_output, 0} = System.cmd("python3", [script], stderr_to_stdout: true)
  end
end
