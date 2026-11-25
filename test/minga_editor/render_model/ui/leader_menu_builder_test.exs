defmodule MingaEditor.RenderModel.UI.LeaderMenuBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Defaults
  alias MingaEditor.RenderModel.UI.LeaderMenuBuilder

  defp menu, do: LeaderMenuBuilder.build(Defaults.leader_trie())

  test "every group and command under SPC appears once, groups before their contents, in which-key order" do
    items = menu()
    paths = Enum.map(items, & &1.path)

    assert paths == Enum.uniq(paths)
    assert Enum.find_index(paths, &(&1 == "a")) < Enum.find_index(paths, &(&1 == "a a"))
    assert Enum.find_index(paths, &(&1 == "a q")) < Enum.find_index(paths, &(&1 == "a q q"))

    # The top level follows the which-key sections: Groups first, then Often.
    top = for %{path: path} <- items, not String.contains?(path, " "), do: path
    assert hd(top) == "a"
    assert Enum.find_index(top, &(&1 == "SPC")) > Enum.find_index(top, &(&1 == ":"))
  end

  test "items carry the label, the command a click runs, the section and the ⌘ equivalent" do
    items = Map.new(menu(), &{&1.path, &1})

    assert %{label: "Minga", kind: :group, command: ""} = items["a"]

    assert %{label: "Stop", kind: :command, command: "agent_abort", section: "Tasks"} =
             items["a s"]

    assert %{command: "save", platform_key: "⌘S"} = items["f s"]
    assert %{command: "quit_all", platform_key: "⌘Q"} = items["q q"]
  end
end
