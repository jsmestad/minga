defmodule Minga.UI.WhichKeyTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Bindings
  alias Minga.UI.WhichKey

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
      children = [{{?f, 0}, "Find file"}, {{?s, 0}, "Save file"}]
      result = WhichKey.format_bindings(children)

      assert Enum.any?(
               result,
               &(&1 == %Minga.UI.WhichKey.Binding{
                   key: "f",
                   description: "Find file",
                   kind: :command,
                   icon: nil
                 })
             )

      assert Enum.any?(
               result,
               &(&1 == %Minga.UI.WhichKey.Binding{
                   key: "s",
                   description: "Save file",
                   kind: :command,
                   icon: nil
                 })
             )
    end

    test "formats :prefix atom label as '+prefix' with group kind" do
      result = WhichKey.format_bindings([{{?f, 0}, :prefix}])
      assert [%Minga.UI.WhichKey.Binding{key: "f", description: "+prefix", kind: :group}] = result
    end

    test "formats :unknown atom label as '?'" do
      result = WhichKey.format_bindings([{{?x, 0}, :unknown}])

      assert result == [
               %Minga.UI.WhichKey.Binding{key: "x", description: "?", kind: :command, icon: nil}
             ]
    end

    test "formats arbitrary atom label as its string form" do
      result = WhichKey.format_bindings([{{?q, 0}, :quit}])

      assert result == [
               %Minga.UI.WhichKey.Binding{
                 key: "q",
                 description: "quit",
                 kind: :command,
                 icon: nil
               }
             ]
    end

    test "attaches icon to known group labels" do
      result = WhichKey.format_bindings([{{?g, 0}, "+git"}])
      assert [%Minga.UI.WhichKey.Binding{kind: :group, icon: icon}] = result
      assert icon != nil
    end

    test "returns nil icon for unknown group labels" do
      result = WhichKey.format_bindings([{{?z, 0}, "+zzz_unknown"}])
      assert [%Minga.UI.WhichKey.Binding{kind: :group, icon: nil}] = result
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
               &(&1 == %Minga.UI.WhichKey.Binding{
                   key: "s",
                   description: "Save file",
                   kind: :command,
                   icon: nil
                 })
             )

      assert Enum.any?(
               bindings,
               &(&1 == %Minga.UI.WhichKey.Binding{
                   key: "f",
                   description: "Find file",
                   kind: :command,
                   icon: nil
                 })
             )
    end

    test "labels prefix-only nodes as '+prefix' with group kind" do
      trie =
        Bindings.new()
        |> Bindings.bind([{?f, 0}, {?s, 0}], :save, "Save")

      # The `f` child is a prefix node with no description.
      bindings = WhichKey.bindings_from_node(trie)

      assert [%Minga.UI.WhichKey.Binding{key: "f", description: "+prefix", kind: :group}] =
               bindings
    end

    test "uses bind_prefix description when set and marks as group" do
      trie =
        Bindings.new()
        |> Bindings.bind([{?f, 0}, {?s, 0}], :save, "Save")
        |> Bindings.bind_prefix([{?f, 0}], "+file")

      bindings = WhichKey.bindings_from_node(trie)

      assert [%Minga.UI.WhichKey.Binding{key: "f", description: "+file", kind: :group, icon: "󰈔"}] =
               bindings
    end

    test "returns empty list for leaf node with no children" do
      trie = Bindings.bind(Bindings.new(), [{?s, 0}], :save, "Save")
      {:command, :save} = Bindings.lookup(trie, {?s, 0})

      # The leaf node (returned via Bindings.lookup → get child) has no children.
      {:ok, leaf} = Map.fetch(trie.children, {?s, 0})
      assert WhichKey.bindings_from_node(leaf) == []
    end
  end

  # ── start_timeout/1 and cancel_timeout/1 ─────────────────────────────────────

  describe "timer functions" do
    test "start_timeout sends :whichkey_timeout after delay" do
      ref = WhichKey.start_timeout(10)
      assert_receive {:whichkey_timeout, ^ref}, 200
    end

    test "cancel_timeout prevents the timer from firing" do
      ref = WhichKey.start_timeout(500)
      :ok = WhichKey.cancel_timeout(ref)
      refute_receive {:whichkey_timeout, ^ref}, 100
    end

    test "start_timeout returns a reference" do
      ref = WhichKey.start_timeout(10_000)
      assert is_reference(ref)
      WhichKey.cancel_timeout(ref)
    end
  end
end
