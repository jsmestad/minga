defmodule Minga.Keymap.ScopeTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Scope

  describe "module_for/1" do
    test "returns Editor module for :editor" do
      assert Scope.module_for(:editor) == Minga.Keymap.Scope.Editor
    end

    test "returns Agent module for :agent" do
      assert Scope.module_for(:agent) == Minga.Keymap.Scope.Agent
    end

    test "returns FileTree module for :file_tree" do
      assert Scope.module_for(:file_tree) == Minga.Keymap.Scope.FileTree
    end

    test "returns nil for unknown scope" do
      assert Scope.module_for(:bogus) == nil
    end
  end

  describe "all_scopes/0" do
    test "returns all three built-in scopes" do
      scopes = Scope.all_scopes()
      assert :editor in scopes
      assert :agent in scopes
      assert :file_tree in scopes
      assert length(scopes) == 3
    end
  end

  describe "resolve_key/4 with :editor scope" do
    test "always returns :not_found (editor scope is pass-through)" do
      assert Scope.resolve_key(:editor, :normal, {?j, 0}) == :not_found
      assert Scope.resolve_key(:editor, :insert, {?a, 0}) == :not_found
    end
  end

  describe "resolve_key/4 with :agent scope" do
    test "resolves j to agent_scroll_down in normal mode" do
      assert {:command, :agent_scroll_down} = Scope.resolve_key(:agent, :normal, {?j, 0})
    end

    test "resolves k to agent_scroll_up in normal mode" do
      assert {:command, :agent_scroll_up} = Scope.resolve_key(:agent, :normal, {?k, 0})
    end

    test "resolves Ctrl+D to agent_scroll_half_down in normal mode" do
      assert {:command, :agent_scroll_half_down} = Scope.resolve_key(:agent, :normal, {?d, 0x02})
    end

    test "resolves G to agent_scroll_bottom in normal mode" do
      assert {:command, :agent_scroll_bottom} = Scope.resolve_key(:agent, :normal, {?G, 0})
    end

    test "g is a prefix in normal mode" do
      assert {:prefix, _node} = Scope.resolve_key(:agent, :normal, {?g, 0})
    end

    test "gg resolves to agent_scroll_top via prefix walk" do
      {:prefix, g_node} = Scope.resolve_key(:agent, :normal, {?g, 0})
      assert {:command, :agent_scroll_top} = Scope.resolve_key_in_node(g_node, {?g, 0})
    end

    test "gf resolves to agent_open_code_block via prefix walk" do
      {:prefix, g_node} = Scope.resolve_key(:agent, :normal, {?g, 0})
      assert {:command, :agent_open_code_block} = Scope.resolve_key_in_node(g_node, {?f, 0})
    end

    test "z is a prefix in normal mode" do
      assert {:prefix, _node} = Scope.resolve_key(:agent, :normal, {?z, 0})
    end

    test "za resolves to agent_toggle_collapse" do
      {:prefix, z_node} = Scope.resolve_key(:agent, :normal, {?z, 0})
      assert {:command, :agent_toggle_collapse} = Scope.resolve_key_in_node(z_node, {?a, 0})
    end

    test "zM resolves to agent_collapse_all" do
      {:prefix, z_node} = Scope.resolve_key(:agent, :normal, {?z, 0})
      assert {:command, :agent_collapse_all} = Scope.resolve_key_in_node(z_node, {?M, 0})
    end

    test "] is a prefix in normal mode" do
      assert {:prefix, _node} = Scope.resolve_key(:agent, :normal, {?], 0})
    end

    test "]c resolves to agent_next_code_block" do
      {:prefix, bracket_node} = Scope.resolve_key(:agent, :normal, {?], 0})

      assert {:command, :agent_next_code_block} =
               Scope.resolve_key_in_node(bracket_node, {?c, 0})
    end

    test "y resolves to agent_copy_code_block in normal mode" do
      assert {:command, :agent_copy_code_block} = Scope.resolve_key(:agent, :normal, {?y, 0})
    end

    test "Y resolves to agent_copy_message in normal mode" do
      assert {:command, :agent_copy_message} = Scope.resolve_key(:agent, :normal, {?Y, 0})
    end

    test "q resolves to agent_close in normal mode" do
      assert {:command, :agent_close} = Scope.resolve_key(:agent, :normal, {?q, 0})
    end

    test "/ resolves to agent_start_search in normal mode" do
      assert {:command, :agent_start_search} = Scope.resolve_key(:agent, :normal, {?/, 0})
    end

    test "? resolves to agent_toggle_help in normal mode" do
      assert {:command, :agent_toggle_help} = Scope.resolve_key(:agent, :normal, {??, 0})
    end

    test "ESC resolves to agent_input_to_normal in insert mode" do
      assert {:command, :agent_input_to_normal} = Scope.resolve_key(:agent, :insert, {27, 0})
    end

    test "Enter resolves to agent_submit_or_newline in insert mode" do
      assert {:command, :agent_submit_or_newline} = Scope.resolve_key(:agent, :insert, {13, 0})
    end

    test "Backspace resolves to agent_input_backspace in insert mode" do
      assert {:command, :agent_input_backspace} = Scope.resolve_key(:agent, :insert, {127, 0})
    end

    test "Ctrl+C resolves to agent_submit_or_abort in insert mode" do
      assert {:command, :agent_submit_or_abort} = Scope.resolve_key(:agent, :insert, {?c, 0x02})
    end

    test "unknown key returns :not_found in normal mode" do
      # tilde is not bound
      assert :not_found = Scope.resolve_key(:agent, :normal, {?~, 0})
    end

    test "normal-mode keys don't resolve in insert mode" do
      # j is bound in normal but not insert
      assert :not_found = Scope.resolve_key(:agent, :insert, {?j, 0})
    end
  end

  describe "resolve_key/4 with :file_tree scope" do
    test "Enter resolves to tree_open_or_toggle" do
      assert {:command, :tree_open_or_toggle} = Scope.resolve_key(:file_tree, :normal, {13, 0})
    end

    test "l resolves to tree_expand" do
      assert {:command, :tree_expand} = Scope.resolve_key(:file_tree, :normal, {?l, 0})
    end

    test "h resolves to tree_collapse" do
      assert {:command, :tree_collapse} = Scope.resolve_key(:file_tree, :normal, {?h, 0})
    end

    test "H resolves to tree_toggle_hidden" do
      assert {:command, :tree_toggle_hidden} = Scope.resolve_key(:file_tree, :normal, {?H, 0})
    end

    test "q resolves to tree_close" do
      assert {:command, :tree_close} = Scope.resolve_key(:file_tree, :normal, {?q, 0})
    end

    test "unknown key returns :not_found" do
      assert :not_found = Scope.resolve_key(:file_tree, :normal, {?x, 0})
    end
  end

  describe "resolve_key/4 with unknown scope" do
    test "returns :not_found" do
      assert :not_found = Scope.resolve_key(:nonexistent, :normal, {?j, 0})
    end
  end

  describe "behaviour contract" do
    for {scope_name, mod} <- [
          editor: Minga.Keymap.Scope.Editor,
          agent: Minga.Keymap.Scope.Agent,
          file_tree: Minga.Keymap.Scope.FileTree
        ] do
      test "#{mod} implements name/0 returning #{scope_name}" do
        assert unquote(mod).name() == unquote(scope_name)
      end

      test "#{mod} implements display_name/0 returning a string" do
        assert is_binary(unquote(mod).display_name())
      end

      test "#{mod} implements keymap/2 returning a trie node" do
        assert %Bindings.Node{} = unquote(mod).keymap(:normal, [])
        assert %Bindings.Node{} = unquote(mod).keymap(:insert, [])
      end

      test "#{mod} implements shared_keymap/0 returning a trie node" do
        assert %Bindings.Node{} = unquote(mod).shared_keymap()
      end
    end
  end

  describe "help_groups/2" do
    test "agent scope returns chat help by default" do
      groups = Scope.help_groups(:agent, :chat)
      assert [_ | _] = groups
      assert {"Navigation", bindings} = List.first(groups)
      assert is_list(bindings)
      assert Enum.any?(bindings, fn {key, _desc} -> String.contains?(key, "j") end)
    end

    test "agent scope returns viewer help for :file_viewer" do
      viewer_groups = Scope.help_groups(:agent, :file_viewer)
      assert [_ | _] = viewer_groups
      # Viewer help has fewer groups than chat help
      chat_groups = Scope.help_groups(:agent, :chat)
      assert Enum.count(viewer_groups) < Enum.count(chat_groups)
    end

    test "editor scope returns empty help" do
      assert [] = Scope.help_groups(:editor, :default)
    end

    test "file_tree scope returns help with tree bindings" do
      groups = Scope.help_groups(:file_tree, :default)
      assert [_ | _] = groups
      all_bindings = Enum.flat_map(groups, fn {_cat, bindings} -> bindings end)
      assert Enum.any?(all_bindings, fn {key, _desc} -> key == "Enter" end)
    end

    test "unknown scope returns empty help" do
      assert [] = Scope.help_groups(:nonexistent, :default)
    end

    test "all help groups have {string, string} binding entries" do
      for scope <- Scope.all_scopes() do
        groups = Scope.help_groups(scope, :default)

        for {category, bindings} <- groups do
          assert is_binary(category), "category should be string in #{scope}"

          for {key, desc} <- bindings do
            assert is_binary(key), "key should be string in #{scope}/#{category}"
            assert is_binary(desc), "desc should be string in #{scope}/#{category}"
          end
        end
      end
    end
  end
end
