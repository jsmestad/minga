defmodule Minga.Scripts.StampRollingAppTest do
  # Starts Python, which shares the host Erlang child-process launcher.
  use ExUnit.Case, async: false
  @moduletag timeout: 30_000

  test "stamps rolling build versions while preserving the app marketing version" do
    script = Path.join(__DIR__, "stamp_rolling_app_test.py")
    {output, status} = System.cmd("python3", [script], stderr_to_stdout: true)
    assert status == 0, output
  end
end
