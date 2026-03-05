defmodule Minga.KeymapTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap
  alias Minga.Keymap.Bindings

  describe "keymap_for/1" do
    test "returns a trie for :normal mode" do
      trie = Keymap.keymap_for(:normal)
      assert is_map(trie)
    end

    test "normal mode trie contains h/j/k/l movement bindings" do
      trie = Keymap.keymap_for(:normal)

      assert {:command, :move_left} = Bindings.lookup(trie, {?h, 0})
      assert {:command, :move_down} = Bindings.lookup(trie, {?j, 0})
      assert {:command, :move_up} = Bindings.lookup(trie, {?k, 0})
      assert {:command, :move_right} = Bindings.lookup(trie, {?l, 0})
    end

    test "normal mode trie contains x and X deletion bindings" do
      trie = Keymap.keymap_for(:normal)

      assert {:command, :delete_at} = Bindings.lookup(trie, {?x, 0})
      assert {:command, :delete_before} = Bindings.lookup(trie, {?X, 0})
    end

    test "normal mode trie contains ZZ and ZQ multi-key bindings" do
      trie = Keymap.keymap_for(:normal)

      # ZZ is a two-key sequence — first Z is a prefix
      assert {:prefix, sub} = Bindings.lookup(trie, {?Z, 0})
      assert {:command, :save} = Bindings.lookup(sub, {?Z, 0})
      assert {:command, :force_quit} = Bindings.lookup(sub, {?Q, 0})
    end

    test "returns a trie for :insert mode" do
      trie = Keymap.keymap_for(:insert)
      assert is_map(trie)
    end

    test "insert mode trie contains Ctrl+S save binding" do
      trie = Keymap.keymap_for(:insert)
      assert {:command, :save} = Bindings.lookup(trie, {?s, 0x02})
    end

    test "insert mode trie contains Ctrl+Q quit binding" do
      trie = Keymap.keymap_for(:insert)
      assert {:command, :quit} = Bindings.lookup(trie, {?q, 0x02})
    end

    test "returns a trie for :visual mode" do
      trie = Keymap.keymap_for(:visual)
      assert is_map(trie)
    end

    test "visual mode trie contains movement and operator bindings" do
      trie = Keymap.keymap_for(:visual)

      assert {:command, :move_left} = Bindings.lookup(trie, {?h, 0})
      assert {:command, :delete_selection} = Bindings.lookup(trie, {?d, 0})
      assert {:command, :yank_selection} = Bindings.lookup(trie, {?y, 0})
      assert {:command, :change_selection} = Bindings.lookup(trie, {?c, 0})
    end

    test "returns a trie for :command mode" do
      trie = Keymap.keymap_for(:command)
      assert is_map(trie)
    end

    test "command mode trie is empty (no bindings defined)" do
      trie = Keymap.keymap_for(:command)
      # Should return :not_found for any key
      assert :not_found = Bindings.lookup(trie, {?a, 0})
    end

    test "each call builds a fresh trie" do
      t1 = Keymap.keymap_for(:normal)
      t2 = Keymap.keymap_for(:normal)
      # Same structure, but not the same reference (fresh build each time)
      assert t1 == t2
    end
  end
end
