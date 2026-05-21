defmodule Minga.Keymap.DefaultsTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Defaults
  alias Minga.Keymap.NormalPrefixes

  describe "normal prefix trie" do
    test "zC and zO route to recursive fold commands" do
      trie = NormalPrefixes.trie()
      assert {:prefix, z_node} = Bindings.lookup(trie, {?z, 0})
      assert {:command, :fold_close_recursive} = Bindings.lookup(z_node, {?C, 0})
      assert {:command, :fold_open_recursive} = Bindings.lookup(z_node, {?O, 0})
    end
  end

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

    # ── Tab / workspace bindings ───────────────────────────────────────────────

    test "SPC t routes workspace bindings to workspace commands" do
      trie = Defaults.leader_trie()
      {:prefix, t_node} = Bindings.lookup(trie, {9, 0})

      assert t_node.description == "+tab"
      assert {:command, :workspace_toggle} = Bindings.lookup(t_node, {9, 0})
      assert {:command, :workspace_next} = Bindings.lookup(t_node, {?N, 0})
      assert {:command, :workspace_prev} = Bindings.lookup(t_node, {?P, 0})
      assert {:command, :workspace_next_agent} = Bindings.lookup(t_node, {?A, 0})
      assert {:command, :manual_workspace} = Bindings.lookup(t_node, {?m, 0})
      assert {:command, :workspace_list} = Bindings.lookup(t_node, {?l, 0})
      assert {:command, :workspace_rename} = Bindings.lookup(t_node, {?r, 0})
      assert {:command, :workspace_set_icon} = Bindings.lookup(t_node, {?i, 0})
      assert {:command, :workspace_close} = Bindings.lookup(t_node, {?D, 0})
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

    test "SPC q q → :quit_all" do
      trie = Defaults.leader_trie()
      {:prefix, q_node} = Bindings.lookup(trie, {?q, 0})
      assert {:command, :quit_all} = Bindings.lookup(q_node, {?q, 0})
    end

    # ── Help bindings ──────────────────────────────────────────────────────────

    test "SPC h f → :describe_function" do
      trie = Defaults.leader_trie()
      {:prefix, h_node} = Bindings.lookup(trie, {?h, 0})
      assert {:command, :describe_function} = Bindings.lookup(h_node, {?f, 0})
    end

    test "SPC h k → :describe_key" do
      trie = Defaults.leader_trie()
      {:prefix, h_node} = Bindings.lookup(trie, {?h, 0})
      assert {:command, :describe_key} = Bindings.lookup(h_node, {?k, 0})
    end

    # ── Code / LSP bindings ───────────────────────────────────────────────────

    test "SPC c h → :call_hierarchy" do
      trie = Defaults.leader_trie()
      {:prefix, c_node} = Bindings.lookup(trie, {?c, 0})
      assert {:command, :call_hierarchy} = Bindings.lookup(c_node, {?h, 0})
    end

    test "SPC c H → :call_hierarchy_outgoing" do
      trie = Defaults.leader_trie()
      {:prefix, c_node} = Bindings.lookup(trie, {?c, 0})
      assert {:command, :call_hierarchy_outgoing} = Bindings.lookup(c_node, {?H, 0})
    end

    test "SPC c v → :selection_expand" do
      trie = Defaults.leader_trie()
      {:prefix, c_node} = Bindings.lookup(trie, {?c, 0})
      assert {:command, :selection_expand} = Bindings.lookup(c_node, {?v, 0})
    end

    test "SPC c V → :selection_shrink" do
      trie = Defaults.leader_trie()
      {:prefix, c_node} = Bindings.lookup(trie, {?c, 0})
      assert {:command, :selection_shrink} = Bindings.lookup(c_node, {?V, 0})
    end

    # ── AI agent bindings ─────────────────────────────────────────────────────

    test "SPC a h → :agent_session_history" do
      trie = Defaults.leader_trie()
      {:prefix, a_node} = Bindings.lookup(trie, {?a, 0})
      assert {:command, :agent_session_history} = Bindings.lookup(a_node, {?h, 0})
    end

    test "SPC a r → :workspace_pending_reviews" do
      trie = Defaults.leader_trie()
      {:prefix, a_node} = Bindings.lookup(trie, {?a, 0})
      assert {:command, :workspace_pending_reviews} = Bindings.lookup(a_node, {?r, 0})
    end

    # ── Search bindings ─────────────────────────────────────────────────────────

    test "SPC s s → :search_buffer" do
      trie = Defaults.leader_trie()
      {:prefix, s_node} = Bindings.lookup(trie, {?s, 0})
      assert {:command, :search_buffer} = Bindings.lookup(s_node, {?s, 0})
    end

    test "SPC s r → :search_and_replace" do
      trie = Defaults.leader_trie()
      {:prefix, s_node} = Bindings.lookup(trie, {?s, 0})
      assert {:command, :search_and_replace} = Bindings.lookup(s_node, {?r, 0})
    end

    test "SPC s j → :document_symbols" do
      trie = Defaults.leader_trie()
      {:prefix, s_node} = Bindings.lookup(trie, {?s, 0})
      assert {:command, :document_symbols} = Bindings.lookup(s_node, {?j, 0})
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

    test "contains structural navigation Alt+ bindings" do
      bindings = Defaults.normal_bindings()
      assert {:nav_parent, _} = bindings[{?h, 0x04}]
      assert {:nav_first_child, _} = bindings[{?l, 0x04}]
      assert {:nav_next_sibling, _} = bindings[{?j, 0x04}]
      assert {:nav_prev_sibling, _} = bindings[{?k, 0x04}]
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
