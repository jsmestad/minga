defmodule Mix.Tasks.App.AssembleTest do
  # Exercises a real Mix subprocess, which can hit the BEAM's erl_child_setup EPIPE race.
  use ExUnit.Case, async: false

  @moduletag :heavy
  @moduletag timeout: 30_000
  @moduletag :tmp_dir

  test "a missing release invalidates the no-build handoff", %{tmp_dir: tmp_dir} do
    handoff = Path.join(tmp_dir, "app-path")
    build_path = Path.join(tmp_dir, "build")
    File.write!(handoff, "/previous/Minga.app\n")

    {output, status} =
      System.cmd("mix", ["app.assemble", "--no-build", "--output-path-file", handoff],
        env: [
          {"MIX_BUILD_PATH", build_path},
          {"MIX_DEPS_PATH", Path.join(tmp_dir, "deps")},
          {"MIX_ENV", "prod"}
        ],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "BEAM release not found at #{build_path}/rel/minga_macos"
    refute File.exists?(handoff)
  end
end
