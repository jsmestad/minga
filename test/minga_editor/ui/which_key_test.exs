defmodule MingaEditor.UI.WhichKeyTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Bindings
  alias MingaEditor.UI.WhichKey

  # ── format_key/1 ────────────────────────────────────────────────────────────

  describe "format_key/1" do
    test "formats SPC (space, codepoint 32) as 'SPC'" do
      assert WhichKey.format_key({32, 0}) == "SPC"
    end

    test "formats ESC (codepoint 27) as 'ESC'" do
      assert WhichKey.format_key({27, 0}) == "ESC"
    end

    test "formats plain letter without modifier" do
      assert WhichKey.format_key({?j, 0}) == "j"
      assert WhichKey.format_key({?s, 0}) == "s"
      assert WhichKey.format_key({?f, 0}) == "f"
    end

    test "formats Ctrl+key with 'C-' prefix" do
      assert WhichKey.format_key({?s, 0x02}) == "C-s"
      assert WhichKey.format_key({?q, 0x02}) == "C-q"
    end

    test "formats Alt+key with 'M-' prefix" do
      assert WhichKey.format_key({?s, 0x04}) == "M-s"
    end

    test "formats Ctrl+Alt+key with 'C-M-' prefix" do
      assert WhichKey.format_key({?s, 0x06}) == "C-M-s"
    end

    test "formats TAB (codepoint 9) as 'TAB'" do
      assert WhichKey.format_key({9, 0}) == "TAB"
    end

    test "formats RET (codepoint 13) as 'RET'" do
      assert WhichKey.format_key({13, 0}) == "RET"
    end

    test "formats uppercase letters" do
      assert WhichKey.format_key({?G, 0}) == "G"
      assert WhichKey.format_key({?Z, 0}) == "Z"
    end
  end

  # ── format_bindings/1 ─────────────────────────────────────────────────────────

  describe "format_bindings/1" do
    test "formats a list of key/label pairs into binding maps" do
      children = [{{?f, 0}, "Find file", :command}, {{?s, 0}, "Save file", :command}]
      result = WhichKey.format_bindings(children)

      assert Enum.any?(
               result,
               &(&1 == %MingaEditor.UI.WhichKey.Binding{
                   key: "f",
                   description: "Find file",
                   kind: :command,
                   codepoint: ?f,
                   modifiers: 0
                 })
             )

      assert Enum.any?(
               result,
               &(&1 == %MingaEditor.UI.WhichKey.Binding{
                   key: "s",
                   description: "Save file",
                   kind: :command,
                   codepoint: ?s,
                   modifiers: 0
                 })
             )
    end

    test "formats an unnamed group as 'More' with group kind" do
      result = WhichKey.format_bindings([{{?f, 0}, :prefix, :group}])

      assert [%MingaEditor.UI.WhichKey.Binding{key: "f", description: "More", kind: :group}] =
               result
    end

    test "group labels read like leaves: a legacy '+label' becomes Title Case" do
      result =
        WhichKey.format_bindings([
          {{?g, 0}, "+git", :group},
          {{?S, 0}, "Session", :group},
          {{?x, 0}, "+context", :group}
        ])

      assert Enum.map(result, & &1.description) == ["Git", "Session", "Context"]
      assert Enum.all?(result, &(&1.kind == :group))
    end

    test "a command label that starts with '+' stays a command" do
      assert [%MingaEditor.UI.WhichKey.Binding{description: "+1 line", kind: :command}] =
               WhichKey.format_bindings([{{?+, 0}, "+1 line", :command}])
    end

    test "formats :unknown atom label as '?'" do
      result = WhichKey.format_bindings([{{?x, 0}, :unknown, :command}])

      assert result == [
               %MingaEditor.UI.WhichKey.Binding{
                 key: "x",
                 description: "?",
                 kind: :command,
                 codepoint: ?x,
                 modifiers: 0
               }
             ]
    end

    test "formats arbitrary atom label as its string form" do
      result = WhichKey.format_bindings([{{?q, 0}, :quit, :command}])

      assert result == [
               %MingaEditor.UI.WhichKey.Binding{
                 key: "q",
                 description: "quit",
                 kind: :command,
                 codepoint: ?q,
                 modifiers: 0
               }
             ]
    end

    test "returns empty list for empty children" do
      assert WhichKey.format_bindings([]) == []
    end
  end

  # ── bindings_from_node/1 ──────────────────────────────────────────────────────

  describe "bindings_from_node/1" do
    test "returns sorted binding maps from a trie node's children" do
      trie =
        Bindings.new()
        |> Bindings.bind([{?s, 0}], :save, "Save file")
        |> Bindings.bind([{?f, 0}], :find, "Find file")

      bindings = WhichKey.bindings_from_node(trie)

      # Should be sorted by key string.
      assert Enum.map(bindings, & &1.key) == ["f", "s"]

      assert Enum.any?(
               bindings,
               &(&1 == %MingaEditor.UI.WhichKey.Binding{
                   key: "s",
                   description: "Save file",
                   kind: :command,
                   codepoint: ?s,
                   modifiers: 0,
                   command: :save
                 })
             )

      assert Enum.any?(
               bindings,
               &(&1 == %MingaEditor.UI.WhichKey.Binding{
                   key: "f",
                   description: "Find file",
                   kind: :command,
                   codepoint: ?f,
                   modifiers: 0,
                   command: :find
                 })
             )
    end

    test "labels prefix-only nodes as 'More' with group kind" do
      trie =
        Bindings.new()
        |> Bindings.bind([{?f, 0}, {?s, 0}], :save, "Save")

      # The `f` child is a prefix node with no description.
      bindings = WhichKey.bindings_from_node(trie)

      assert [%MingaEditor.UI.WhichKey.Binding{key: "f", description: "More", kind: :group}] =
               bindings
    end

    test "uses bind_prefix description when set and marks as group" do
      trie =
        Bindings.new()
        |> Bindings.bind([{?f, 0}, {?s, 0}], :save, "Save")
        |> Bindings.bind_prefix([{?f, 0}], "Files")

      bindings = WhichKey.bindings_from_node(trie)

      assert [
               %MingaEditor.UI.WhichKey.Binding{
                 key: "f",
                 description: "Files",
                 kind: :group
               }
             ] =
               bindings
    end

    test "orders groups first, then commands, each case-insensitive with lowercase first" do
      trie =
        Bindings.new()
        |> Bindings.bind([{?S, 0}], :stop_session, "Stop session")
        |> Bindings.bind([{?s, 0}], :stop, "Stop")
        |> Bindings.bind([{?a, 0}], :tasks, "Tasks")
        |> Bindings.bind([{?q, 0}, {?q, 0}], :queue, "Open queue")
        |> Bindings.bind_prefix([{?q, 0}], "Queue")

      assert Enum.map(WhichKey.bindings_from_node(trie), & &1.key) == ["q", "a", "s", "S"]
    end

    test "returns empty list for leaf node with no children" do
      trie = Bindings.bind(Bindings.new(), [{?s, 0}], :save, "Save")
      {:command, :save} = Bindings.lookup(trie, {?s, 0})

      # The leaf node (returned via Bindings.lookup → get child) has no children.
      {:ok, leaf} = Map.fetch(trie.children, {?s, 0})
      assert WhichKey.bindings_from_node(leaf) == []
    end
  end
end
