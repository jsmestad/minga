defmodule Minga.Keymap.SharedGroupsTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.SharedGroups

  describe "get/1" do
    test "returns bindings for all known groups" do
      for name <- SharedGroups.group_names() do
        bindings = SharedGroups.get(name)
        assert is_list(bindings), "group #{name} should return a list"
        assert [_ | _] = bindings, "group #{name} should not be empty"

        for {keys, command, description} <- bindings do
          assert is_list(keys), "keys should be a list in group #{name}"
          assert is_atom(command), "command should be an atom in group #{name}"
          assert is_binary(description), "description should be a string in group #{name}"
        end
      end
    end

    test "raises on unknown group" do
      assert_raise ArgumentError, ~r/unknown shared group/, fn ->
        SharedGroups.get(:nonexistent)
      end
    end
  end

  describe "ctrl_agent_common" do
    test "contains expected Ctrl bindings" do
      bindings = SharedGroups.ctrl_agent_common()
      commands = Enum.map(bindings, fn {_keys, cmd, _desc} -> cmd end)

      assert :agent_ctrl_c in commands
      assert :agent_scroll_half_down in commands
      assert :agent_scroll_half_up in commands
      assert :agent_clear_chat in commands
      assert :agent_save_buffer in commands
      assert :agent_unfocus_and_quit in commands
    end
  end

  describe "cua_navigation" do
    test "includes both Kitty and macOS arrow encodings" do
      bindings = SharedGroups.cua_navigation()
      keys = Enum.map(bindings, fn {[{cp, _mods}], _cmd, _desc} -> cp end)

      # Kitty protocol
      assert 57_352 in keys
      assert 57_353 in keys
      # macOS
      assert 0xF700 in keys
      assert 0xF701 in keys
    end
  end

  describe "cua_cmd_chords" do
    test "includes both Cmd and Ctrl variants" do
      bindings = SharedGroups.cua_cmd_chords()

      commands_by_mod =
        Enum.group_by(bindings, fn {[{_cp, mods}], _cmd, _desc} -> mods end)

      # Cmd variants (0x08)
      assert Map.has_key?(commands_by_mod, 0x08)
      # Ctrl variants (0x02)
      assert Map.has_key?(commands_by_mod, 0x02)
    end
  end

  describe "merge_bindings/2" do
    test "merges binding list into a trie" do
      bindings = [
        {[{?j, 0}], :move_down, "Move down"},
        {[{?k, 0}], :move_up, "Move up"}
      ]

      trie = Bindings.merge_bindings(Bindings.new(), bindings)

      assert {:command, :move_down} = Bindings.lookup(trie, {?j, 0})
      assert {:command, :move_up} = Bindings.lookup(trie, {?k, 0})
    end

    test "later bindings override earlier ones on same key" do
      bindings = [
        {[{?j, 0}], :first, "First"},
        {[{?j, 0}], :second, "Second"}
      ]

      trie = Bindings.merge_bindings(Bindings.new(), bindings)
      assert {:command, :second} = Bindings.lookup(trie, {?j, 0})
    end
  end

  describe "merge_bindings/3 with exclusions" do
    test "excludes commands by name" do
      bindings = [
        {[{?j, 0}], :move_down, "Move down"},
        {[{?q, 0}], :quit_editor, "Quit"}
      ]

      trie = Bindings.merge_bindings(Bindings.new(), bindings, exclude: [:quit_editor])

      assert {:command, :move_down} = Bindings.lookup(trie, {?j, 0})
      assert :not_found = Bindings.lookup(trie, {?q, 0})
    end

    test "empty exclusion list includes everything" do
      bindings = [{[{?j, 0}], :move_down, "Move down"}]
      trie = Bindings.merge_bindings(Bindings.new(), bindings, exclude: [])
      assert {:command, :move_down} = Bindings.lookup(trie, {?j, 0})
    end
  end

  describe "merge_group/2" do
    test "merges a named group into a trie" do
      trie = Bindings.merge_group(Bindings.new(), :ctrl_agent_common)

      # Ctrl+C should be bound
      assert {:command, :agent_ctrl_c} = Bindings.lookup(trie, {?c, 0x02})
    end
  end

  describe "merge_group/3 with exclusions" do
    test "excludes specific commands from a group" do
      trie =
        Bindings.merge_group(Bindings.new(), :ctrl_agent_common, exclude: [:agent_ctrl_c])

      # Ctrl+C excluded
      assert :not_found = Bindings.lookup(trie, {?c, 0x02})
      # Ctrl+D still present
      assert {:command, :agent_scroll_half_down} = Bindings.lookup(trie, {?d, 0x02})
    end
  end

  describe "scope-specific overrides win over group bindings" do
    test "scope binding applied after merge overrides group binding" do
      trie =
        Bindings.new()
        |> Bindings.merge_group(:ctrl_agent_common)
        # Scope-specific override: Ctrl+D gets a different command
        |> Bindings.bind([{?d, 0x02}], :custom_scroll, "Custom scroll")

      assert {:command, :custom_scroll} = Bindings.lookup(trie, {?d, 0x02})
      # Other group bindings unaffected
      assert {:command, :agent_ctrl_c} = Bindings.lookup(trie, {?c, 0x02})
    end
  end
end
