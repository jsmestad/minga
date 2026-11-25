defmodule MingaAgent.Changeset.Overlay.NativeClonerTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Changeset.Overlay.NativeCloner

  describe "exit_result/2" do
    test "status 0 is a complete clone" do
      assert NativeCloner.exit_result(0, "") == :ok
    end

    test "status 3 is unsupported, so the overlay falls back to links, and keeps the first output line" do
      output = "minga-clone-tree: clonefile /tmp/o/node_modules: OPNOTSUPP (45)\nsecond line\n"

      assert NativeCloner.exit_result(3, output) ==
               {:error,
                {:unsupported, "minga-clone-tree: clonefile /tmp/o/node_modules: OPNOTSUPP (45)"}}
    end

    test "every other status is a real failure with its status and first output line" do
      for {status, output} <- [
            {4, "minga-clone-tree: mkdir /tmp/o/node_modules: EXIST (17)\n"},
            {2, "usage: minga-clone-tree SOURCE TARGET\n"},
            {1, "error: Unexpected\n"},
            {134, ""}
          ] do
        expected = output |> String.split("\n") |> hd()

        assert NativeCloner.exit_result(status, output) ==
                 {:error, {:clone_failed, status, expected}}
      end
    end
  end
end
