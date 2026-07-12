defmodule Minga.Scripts.MacosReleaseOptimizationTest do
  # Runs a shell verifier against fixture output and therefore invokes an OS process.
  use ExUnit.Case, async: false

  @moduletag :heavy

  @script Path.join([File.cwd!(), "scripts", "check_macos_release_optimization"])
  @fixtures Path.join([File.cwd!(), "test", "fixtures", "xcodebuild"])

  test "accepts a Release Minga target optimized with -O" do
    assert {"Minga Release optimization: -O\n", 0} =
             System.cmd(@script, [Path.join(@fixtures, "minga-release-optimized.txt")])
  end

  test "rejects a Release Minga target optimized with -Onone" do
    {_output, status} =
      System.cmd(@script, [Path.join(@fixtures, "minga-release-unoptimized.txt")],
        stderr_to_stdout: true
      )

    assert status != 0
  end
end
