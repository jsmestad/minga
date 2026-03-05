defmodule Minga.Keymap.DefaultsTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Defaults
  alias Minga.Keymap.Bindings

  describe "leader_trie/0" do
    test "returns a non-empty trie node" do
      trie = Defaults.leader_trie()
      assert map_size(trie.children) > 0
    end

    test "SPC f is a prefix node labelled '+file'" do
      trie = Defaults.leader_trie()
      assert {:prefix, f_node} = Bindings.lookup(trie, {?f, 0})
      # The prefix node should have the '+file' description.
      assert f_node.description == "+file"
    end

    test "SPC b is a prefix node labelled '+buffer'" do
      trie = Defaults.leader_trie()
      assert {:prefix, b_node} = Bindings.lookup(trie, {?b, 0})
      assert b_node.description == "+buffer"
    end

    test "SPC w is a prefix node labelled '+window'" do
      trie = Defaults.leader_trie()
      assert {:prefix, w_node} = Bindings.lookup(trie, {?w, 0})
      assert w_node.description == "+window"
    end

    test "SPC q is a prefix node labelled '+quit'" do
      trie = Defaults.leader_trie()
      assert {:prefix, q_node} = Bindings.lookup(trie, {?q, 0})
      assert q_node.description == "+quit"
    end

    test "SPC h is a prefix node labelled '+help'" do
      trie = Defaults.leader_trie()
      assert {:prefix, h_node} = Bindings.lookup(trie, {?h, 0})
      assert h_node.description == "+help"
    end

    # ── File bindings ──────────────────────────────────────────────────────────

    test "SPC f f → :find_file" do
      trie = Defaults.leader_trie()
      {:prefix, f_node} = Bindings.lookup(trie, {?f, 0})
      assert {:command, :find_file} = Bindings.lookup(f_node, {?f, 0})
    end

    test "SPC f s → :save" do
      trie = Defaults.leader_trie()
      {:prefix, f_node} = Bindings.lookup(trie, {?f, 0})
      assert {:command, :save} = Bindings.lookup(f_node, {?s, 0})
    end

    # ── Buffer bindings ────────────────────────────────────────────────────────

    test "SPC b b → :buffer_list" do
      trie = Defaults.leader_trie()
      {:prefix, b_node} = Bindings.lookup(trie, {?b, 0})
      assert {:command, :buffer_list} = Bindings.lookup(b_node, {?b, 0})
    end

    test "SPC b d → :kill_buffer" do
      trie = Defaults.leader_trie()
      {:prefix, b_node} = Bindings.lookup(trie, {?b, 0})
      assert {:command, :kill_buffer} = Bindings.lookup(b_node, {?d, 0})
    end

    # ── Window bindings ────────────────────────────────────────────────────────

    test "SPC w h → :window_left" do
      trie = Defaults.leader_trie()
      {:prefix, w_node} = Bindings.lookup(trie, {?w, 0})
      assert {:command, :window_left} = Bindings.lookup(w_node, {?h, 0})
    end

    test "SPC w j → :window_down" do
      trie = Defaults.leader_trie()
      {:prefix, w_node} = Bindings.lookup(trie, {?w, 0})
      assert {:command, :window_down} = Bindings.lookup(w_node, {?j, 0})
    end

    test "SPC w k → :window_up" do
      trie = Defaults.leader_trie()
      {:prefix, w_node} = Bindings.lookup(trie, {?w, 0})
      assert {:command, :window_up} = Bindings.lookup(w_node, {?k, 0})
    end

    test "SPC w l → :window_right" do
      trie = Defaults.leader_trie()
      {:prefix, w_node} = Bindings.lookup(trie, {?w, 0})
      assert {:command, :window_right} = Bindings.lookup(w_node, {?l, 0})
    end

    test "SPC w v → :split_vertical" do
      trie = Defaults.leader_trie()
      {:prefix, w_node} = Bindings.lookup(trie, {?w, 0})
      assert {:command, :split_vertical} = Bindings.lookup(w_node, {?v, 0})
    end

    test "SPC w s → :split_horizontal" do
      trie = Defaults.leader_trie()
      {:prefix, w_node} = Bindings.lookup(trie, {?w, 0})
      assert {:command, :split_horizontal} = Bindings.lookup(w_node, {?s, 0})
    end

    # ── Quit bindings ──────────────────────────────────────────────────────────

    test "SPC q q → :quit" do
      trie = Defaults.leader_trie()
      {:prefix, q_node} = Bindings.lookup(trie, {?q, 0})
      assert {:command, :quit} = Bindings.lookup(q_node, {?q, 0})
    end

    # ── Help bindings ──────────────────────────────────────────────────────────

    test "SPC h k → :describe_key" do
      trie = Defaults.leader_trie()
      {:prefix, h_node} = Bindings.lookup(trie, {?h, 0})
      assert {:command, :describe_key} = Bindings.lookup(h_node, {?k, 0})
    end

    # ── Negative cases ─────────────────────────────────────────────────────────

    test "unknown leader prefix returns :not_found" do
      trie = Defaults.leader_trie()
      assert :not_found = Bindings.lookup(trie, {?x, 0})
    end
  end

  describe "leader_key/0" do
    test "returns the SPC key tuple" do
      assert Defaults.leader_key() == {32, 0}
    end
  end

  describe "all_bindings/0" do
    test "returns a non-empty list of binding tuples" do
      bindings = Defaults.all_bindings()
      assert is_list(bindings)
      assert match?([_ | _], bindings)
    end

    test "each binding is a {keys, command, description} tuple" do
      for {keys, command, description} <- Defaults.all_bindings() do
        assert is_list(keys)
        assert is_atom(command)
        assert is_binary(description)
      end
    end
  end

  describe "normal_bindings/0" do
    test "returns a non-empty map" do
      bindings = Defaults.normal_bindings()
      assert is_map(bindings)
      assert map_size(bindings) > 0
    end

    test "contains core movement keys" do
      bindings = Defaults.normal_bindings()
      assert {_, _} = bindings[{?h, 0}]
      assert {_, _} = bindings[{?j, 0}]
      assert {_, _} = bindings[{?k, 0}]
      assert {_, _} = bindings[{?l, 0}]
    end

    test "contains Ctrl+ bindings" do
      bindings = Defaults.normal_bindings()
      assert {_, _} = bindings[{?d, 0x02}]
      assert {_, _} = bindings[{?u, 0x02}]
    end

    test "contains operator keys" do
      bindings = Defaults.normal_bindings()
      assert {_, _} = bindings[{?d, 0}]
      assert {_, _} = bindings[{?c, 0}]
      assert {_, _} = bindings[{?y, 0}]
    end

    test "each entry is {command_atom, description_string}" do
      for {_key, {command, description}} <- Defaults.normal_bindings() do
        assert is_atom(command)
        assert is_binary(description)
      end
    end
  end
end
