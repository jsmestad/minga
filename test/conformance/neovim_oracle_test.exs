defmodule Minga.Conformance.NeovimOracleTest do
  # This test invokes nvim as an OS process, so it runs serially to avoid erl_child_setup EPIPE races.
  use ExUnit.Case, async: false

  alias Minga.Test.NeovimOracle

  @moduletag :conformance
  @moduletag timeout: 30_000

  test "runs scenarios through Neovim and returns results keyed by name" do
    assert {:ok, results} = NeovimOracle.run(fake_scenarios(), 2_000)
    assert results["oracle h"].line == 0
    assert results["oracle h"].col == 1
    assert results["oracle dw"].content == "two"
  end

  test "times out a hung nvim process" do
    fake_nvim("#!/usr/bin/env bash\nsleep 5\n", fn nvim ->
      assert {:error, {:nvim_timeout, 50}} =
               NeovimOracle.run_with_executable(nvim, fake_scenarios(), 50)
    end)
  end

  test "captures insert mode after change operator transitions" do
    scenarios = [
      %{
        name: "oracle cw mode",
        type: :operator,
        content: "one two",
        cursor: %{line: 0, col: 0},
        keys: "cw",
        compare: :mode
      }
    ]

    assert {:ok, results} = NeovimOracle.run(scenarios, 2_000)
    assert results["oracle cw mode"].mode == "i"
  end

  test "reports invalid oracle output" do
    assert {:error, {:invalid_output, "junk before json"}} =
             NeovimOracle.parse_output("junk before json\n")
  end

  defp fake_scenarios do
    [
      %{
        name: "oracle h",
        type: :motion,
        content: "abc",
        cursor: %{line: 0, col: 2},
        keys: "h",
        compare: :cursor
      },
      %{
        name: "oracle dw",
        type: :operator,
        content: "one two",
        cursor: %{line: 0, col: 0},
        keys: "dw",
        compare: :both
      }
    ]
  end

  defp fake_nvim(script, fun) do
    dir = Path.join(System.tmp_dir!(), "minga-fake-nvim-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    path = Path.join(dir, "nvim")
    File.write!(path, String.trim_leading(script))
    File.chmod!(path, 0o755)

    try do
      fun.(path)
    after
      File.rm_rf!(dir)
    end
  end
end
