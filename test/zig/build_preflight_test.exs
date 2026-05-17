# This module shells out to zig in a temporary directory to verify the build preflight message.
defmodule Minga.ZigBuildPreflightTest do
  @moduledoc """
  Verifies the Zig build preflight fails fast with an actionable generated-artifact message.
  """

  # async: false - shells out to the Zig CLI in a temp checkout to verify the actionable failure message.
  use ExUnit.Case, async: false

  @repo_root File.cwd!()
  @zig_bin System.find_executable("zig")

  test "zig build test fails fast with actionable guidance when generated files are missing" do
    zig_bin = @zig_bin || flunk("zig executable not found on PATH")

    with_temp_zig_dir(fn dir ->
      File.cp!(Path.join([@repo_root, "zig", "build.zig"]), Path.join(dir, "build.zig"))
      File.cp!(Path.join([@repo_root, ".tool-versions"]), Path.join(dir, ".tool-versions"))

      {output, code} = System.cmd(zig_bin, ["build", "test"], cd: dir, stderr_to_stdout: true)

      assert code == 1
      assert output =~ "missing generated Zig protocol artifacts"
      assert output =~ "Run `mix protocol.gen`"
      assert output =~ "src/generated/protocol_opcodes.zig"
      assert output =~ "src/generated/protocol_schema_test.zig"
    end)
  end

  @spec with_temp_zig_dir((Path.t() -> any())) :: any()
  defp with_temp_zig_dir(fun) do
    dir =
      Path.join(System.tmp_dir!(), "zig-build-preflight-#{System.unique_integer([:positive])}")

    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    try do
      fun.(dir)
    after
      File.rm_rf!(dir)
    end
  end
end
