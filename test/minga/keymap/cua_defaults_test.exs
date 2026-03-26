defmodule Minga.Keymap.CUADefaultsTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.CUADefaults

  # Arrow key codepoints (Kitty protocol)
  @arrow_up 57_352
  @arrow_down 57_353

  # macOS NSEvent arrow keys
  @ns_up 0xF700
  @ns_down 0xF701

  @cmd 0x08
  @shift 0x01

  describe "navigation_trie/0" do
    test "arrow up resolves to :move_up" do
      trie = CUADefaults.navigation_trie()
      assert {:command, :move_up} = Bindings.lookup(trie, {@arrow_up, 0})
    end

    test "arrow down resolves to :move_down" do
      trie = CUADefaults.navigation_trie()
      assert {:command, :move_down} = Bindings.lookup(trie, {@arrow_down, 0})
    end

    test "macOS NSEvent arrows also work" do
      trie = CUADefaults.navigation_trie()
      assert {:command, :move_up} = Bindings.lookup(trie, {@ns_up, 0})
      assert {:command, :move_down} = Bindings.lookup(trie, {@ns_down, 0})
    end

    test "unbound key returns :not_found" do
      trie = CUADefaults.navigation_trie()
      assert :not_found = Bindings.lookup(trie, {?j, 0})
    end
  end

  describe "cmd_chords_trie/0" do
    test "Cmd+C resolves to :yank_visual_selection" do
      trie = CUADefaults.cmd_chords_trie()
      assert {:command, :yank_visual_selection} = Bindings.lookup(trie, {?c, @cmd})
    end

    test "Cmd+Z resolves to :undo" do
      trie = CUADefaults.cmd_chords_trie()
      assert {:command, :undo} = Bindings.lookup(trie, {?z, @cmd})
    end

    test "Cmd+Shift+Z resolves to :redo" do
      trie = CUADefaults.cmd_chords_trie()
      assert {:command, :redo} = Bindings.lookup(trie, {?z, @cmd ||| @shift})
    end

    test "Cmd+S resolves to :save" do
      trie = CUADefaults.cmd_chords_trie()
      assert {:command, :save} = Bindings.lookup(trie, {?s, @cmd})
    end
  end

  describe "horizontal_nav_trie/0" do
    test "provides left and right arrow bindings" do
      trie = CUADefaults.horizontal_nav_trie()
      assert {:command, :move_left} = Bindings.lookup(trie, {57_350, 0})
      assert {:command, :move_right} = Bindings.lookup(trie, {57_351, 0})
    end
  end
end
