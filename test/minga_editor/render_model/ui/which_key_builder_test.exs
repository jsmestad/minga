defmodule MingaEditor.RenderModel.UI.WhichKeyBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Defaults
  alias Minga.RenderModel.UI.WhichKey
  alias MingaEditor.RenderModel.UI.WhichKeyBuilder
  alias MingaEditor.State.WhichKey, as: WhichKeyState
  alias MingaEditor.UI.WhichKey.Counts

  defp leader_node(path) do
    Enum.reduce(path, Defaults.leader_trie(), fn key, node ->
      {:prefix, child} = Bindings.lookup(node, key)
      child
    end)
  end

  # Opens which-key the way the leader does: begin at SPC, then progress one key at a time.
  defp shown(path) do
    state = WhichKeyState.begin(%WhichKeyState{}, Defaults.leader_trie(), ["SPC"])

    path
    |> Enum.with_index(1)
    |> Enum.reduce(state, fn {_key, depth}, acc ->
      keys = Enum.take(path, depth)
      formatted = ["SPC" | Enum.map(keys, &Bindings.format_key/1)]
      WhichKeyState.progress(acc, leader_node(keys), formatted)
    end)
    |> WhichKeyState.reveal(state.generation + length(path))
  end

  defp sections(%WhichKey{entries: entries}) do
    entries
    |> Enum.chunk_by(& &1.section)
    |> Enum.map(fn [first | _] = chunk -> {first.section, Enum.map(chunk, & &1.key)} end)
  end

  test "a hidden or empty state builds a hidden panel" do
    assert %WhichKey{visible: false} = WhichKeyBuilder.build(%WhichKeyState{show: false})

    assert %WhichKey{visible: false} =
             WhichKeyBuilder.build(%WhichKeyState{show: true, node: nil})
  end

  test "SPC lists Groups and Often in the declared order, the rest under More" do
    model = WhichKeyBuilder.build(shown([]))

    assert [{"Groups", groups}, {"Often", often}, {"More", more} | []] = sections(model)
    bound = model.entries |> MapSet.new(& &1.key)

    # The git extension owns SPC g, so the default trie may not bind it; declared keys that are unbound are skipped.
    assert groups == Enum.filter(~w(a s c g f b w o h t q :), &MapSet.member?(bound, &1))
    assert often == ["SPC", ",", "/"]
    # Every bound root key is listed exactly once.
    assert Enum.sort(groups ++ often ++ more) ==
             Defaults.leader_trie()
             |> Bindings.children()
             |> Enum.map(&Bindings.format_key(elem(&1, 0)))
             |> Enum.sort()

    assert model.path == "SPC"
    assert model.breadcrumb == [%{key: "SPC", label: "Leader", path: "SPC"}]
    assert model.hints == [%{key: "⌫", label: "back"}, %{key: "esc", label: "close"}]
  end

  test "SPC a reads Tasks, Conversation, Changes, More, with a breadcrumb back to SPC" do
    model = WhichKeyBuilder.build(shown([{?a, 0}]))

    assert [{"Tasks", _}, {"Conversation", _}, {"Changes", _}, {"More", ["x", "S" | _]}] =
             sections(model)

    assert model.path == "SPC a"

    assert model.breadcrumb == [
             %{key: "SPC", label: "", path: "SPC"},
             %{key: "a", label: "Minga", path: "SPC a"}
           ]

    assert %{label: "Queue ›", kind: :group} = Enum.find(model.entries, &(&1.key == "q"))

    assert %{label: "Stop", kind: :command, codepoint: ?s, modifiers: 0} =
             Enum.find(model.entries, &(&1.key == "s"))
  end

  test "a group opened through a stand-in node keeps its label, and parents follow the prefix" do
    root = Defaults.leader_trie()
    filetype_trie = Bindings.bind(Bindings.new(), [{?t, 0}], :test_file, "Test file")

    state =
      %WhichKeyState{}
      |> WhichKeyState.begin(root, ["SPC"])
      |> WhichKeyState.progress(filetype_trie, ["SPC", "m"], "Filetype")

    assert state.labels == ["Leader", "Filetype"]
    assert {:ok, ^root, ["SPC"]} = WhichKeyState.parent(state)

    back = WhichKeyState.progress(state, root, ["SPC"])
    assert back.labels == ["Leader"]
    assert WhichKeyState.parent(back) == :top
  end

  test "a prefix without declared sections lists groups first in one unnamed section" do
    model = WhichKeyBuilder.build(shown([{?c, 0}]))

    assert [{"", keys}] = sections(model)
    assert hd(keys) == "l"
    assert %{kind: :group, label: "LSP ›"} = hd(model.entries)
  end

  test "live counts follow the facts on every build, so they change while the panel is open" do
    state = shown([])
    counts = Counts.from_facts(%{needs_you_count: 1, diagnostic_counts: {2, 0, 0, 0}})

    model = WhichKeyBuilder.build(state, counts: counts)
    assert %{count: "· 1 needs you"} = Enum.find(model.entries, &(&1.key == "a"))
    assert %{count: "· 2 errors"} = Enum.find(model.entries, &(&1.key == "c"))
    assert %{count: ""} = Enum.find(model.entries, &(&1.key == "f"))

    later = WhichKeyBuilder.build(state, counts: Counts.from_facts(%{needs_you_count: 3}))
    assert %{count: "· 3 needs you"} = Enum.find(later.entries, &(&1.key == "a"))

    minga = WhichKeyBuilder.build(shown([{?a, 0}]), counts: counts)
    assert minga.count == "· 1 needs you"
  end

  test "platform keys show only for native GUI frontends" do
    state = shown([{?f, 0}])

    gui = WhichKeyBuilder.build(state, platform_keys?: true)
    assert %{platform_key: "⌘S"} = Enum.find(gui.entries, &(&1.key == "s"))

    tui = WhichKeyBuilder.build(state, platform_keys?: false)
    assert Enum.all?(tui.entries, &(&1.platform_key == ""))
  end

  test "groups read like leaves: Title Case label with a trailing chevron" do
    node =
      Bindings.new()
      |> Bindings.bind([{?g, 0}, {?s, 0}], :git_status, "Git status")
      |> Bindings.bind_prefix([{?g, 0}], "+git")

    state = %WhichKeyState{show: true, node: node, prefix_keys: ["SPC", "x"], labels: ["", "X"]}
    assert [%{label: "Git ›", kind: :group}] = WhichKeyBuilder.build(state).entries
  end

  test "lists the active picker and prompt scopes' keys" do
    picker = Minga.Keymap.Scope.Picker.keymap(:insert, picker_split: true)

    labels =
      WhichKeyBuilder.build(%WhichKeyState{show: true, node: picker}).entries
      |> MapSet.new(& &1.label)

    for label <- [
          "Next",
          "Previous",
          "Open the selection",
          "Open in a split",
          "Act on the highlighted row",
          "Close"
        ] do
      assert label in labels
    end

    prompt = Minga.Keymap.Scope.Prompt.keymap(:insert, prompt_list: true)

    labels =
      WhichKeyBuilder.build(%WhichKeyState{show: true, node: prompt}).entries
      |> MapSet.new(& &1.label)

    for label <- ["Run", "Cancel", "Complete", "Next", "Previous"], do: assert(label in labels)
  end
end
