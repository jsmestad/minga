defmodule MingaEditor.RenderModel.UI.LeaderMenuBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Bindings
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
    assert Enum.find_index(top, &(&1 == "SPC")) > Enum.find_index(top, &(&1 == "q"))
    assert Enum.find_index(top, &(&1 == ":")) > Enum.find_index(top, &(&1 == "SPC"))
  end

  test "items carry the label, the command a click runs, the section and the ⌘ equivalent" do
    items = Map.new(menu(), &{&1.path, &1})

    assert %{label: "Minga", kind: :group, command: ""} = items["a"]

    assert %{label: "Stop", kind: :command, command: "agent_abort", section: "Tasks"} =
             items["a s"]

    assert %{command: "save", platform_key: "⌘S"} = items["f s"]
    assert %{command: "quit_all", platform_key: "⌘Q"} = items["q q"]
  end

  test "the active filetype replaces the global Filetype commands but not the group" do
    global =
      Bindings.bind(Defaults.leader_trie(), [{?m, 0}, {?x, 0}], :minibuffer, "Global action")

    filetype = Bindings.bind(Bindings.new(), [{?a, 0}], :alternate_file, "Alternate file")

    fallback = Map.new(LeaderMenuBuilder.build(global), &{&1.path, &1})
    active = Map.new(LeaderMenuBuilder.build(global, filetype), &{&1.path, &1})

    assert %{label: "Filetype", kind: :group} = active["m"]
    assert %{command: "minibuffer"} = fallback["m x"]
    refute Map.has_key?(active, "m x")
    assert %{command: "alternate_file"} = active["m a"]
  end
end
