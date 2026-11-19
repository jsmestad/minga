defmodule Minga.Scripts.PublishHomebrewTapTest do
  # System.cmd opens a real OS port for Python and Git; serialize it against other subprocess tests.
  use ExUnit.Case, async: false

  @tag timeout: 60_000
  test "publishes an exact recipe pair atomically and refuses stale or changed input" do
    script = Path.join(__DIR__, "publish_homebrew_tap_test.py")
    {output, status} = System.cmd("python3", ["-B", script], stderr_to_stdout: true)
    assert status == 0, output
  end
end
