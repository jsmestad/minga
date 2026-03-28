defmodule Minga.Keymap.Scope.AgentGroupsTest do
  @moduledoc "Verifies the agent scope uses shared groups correctly."
  use ExUnit.Case, async: true

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Scope.Agent, as: AgentScope

  @ctrl 0x02

  describe "insert mode trie (from shared groups)" do
    setup do
      {:ok, trie: AgentScope.keymap(:insert, [])}
    end

    test "Ctrl+C from ctrl_agent_common group", %{trie: trie} do
      assert {:command, :agent_ctrl_c} = Bindings.lookup(trie, {?c, @ctrl})
    end

    test "Ctrl+S from ctrl_agent_common group", %{trie: trie} do
      assert {:command, :agent_save_buffer} = Bindings.lookup(trie, {?s, @ctrl})
    end

    test "Ctrl+L from ctrl_agent_common group", %{trie: trie} do
      assert {:command, :agent_clear_chat} = Bindings.lookup(trie, {?l, @ctrl})
    end

    test "Ctrl+Q from ctrl_agent_common group", %{trie: trie} do
      assert {:command, :agent_unfocus_and_quit} = Bindings.lookup(trie, {?q, @ctrl})
    end

    test "Ctrl+D/U from group with insert-specific descriptions", %{trie: trie} do
      assert {:command, :agent_scroll_half_down} = Bindings.lookup(trie, {?d, @ctrl})
      assert {:command, :agent_scroll_half_up} = Bindings.lookup(trie, {?u, @ctrl})
    end

    test "newline variants from shared group", %{trie: trie} do
      # Shift+Enter
      assert {:command, :agent_insert_newline} = Bindings.lookup(trie, {13, 0x01})
      # Ctrl+J
      assert {:command, :agent_insert_newline} = Bindings.lookup(trie, {?j, @ctrl})
      # Raw LF
      assert {:command, :agent_insert_newline} = Bindings.lookup(trie, {0x0A, 0})
      # Alt+Enter
      assert {:command, :agent_insert_newline} = Bindings.lookup(trie, {13, 0x04})
    end

    test "scope-specific bindings still present", %{trie: trie} do
      # ESC
      assert {:command, :agent_input_to_normal} = Bindings.lookup(trie, {27, 0})
      # Enter
      assert {:command, :agent_submit_or_newline} = Bindings.lookup(trie, {13, 0})
      # Backspace
      assert {:command, :agent_input_backspace} = Bindings.lookup(trie, {127, 0})
    end
  end

  describe "input_normal mode trie (from shared groups)" do
    setup do
      {:ok, trie: AgentScope.keymap(:input_normal, [])}
    end

    test "Ctrl bindings from ctrl_agent_common group", %{trie: trie} do
      assert {:command, :agent_ctrl_c} = Bindings.lookup(trie, {?c, @ctrl})
      assert {:command, :agent_scroll_half_down} = Bindings.lookup(trie, {?d, @ctrl})
      assert {:command, :agent_scroll_half_up} = Bindings.lookup(trie, {?u, @ctrl})
      assert {:command, :agent_clear_chat} = Bindings.lookup(trie, {?l, @ctrl})
      assert {:command, :agent_save_buffer} = Bindings.lookup(trie, {?s, @ctrl})
      assert {:command, :agent_unfocus_and_quit} = Bindings.lookup(trie, {?q, @ctrl})
    end

    test "scope-specific q binding", %{trie: trie} do
      assert {:command, :agent_unfocus_input} = Bindings.lookup(trie, {?q, 0})
    end
  end

  describe "included_groups/0" do
    test "declares the groups this scope uses" do
      groups = AgentScope.included_groups()

      group_names =
        Enum.map(groups, fn
          {name, _opts} -> name
          name -> name
        end)

      assert :ctrl_agent_common in group_names
      assert :newline_variants in group_names
      assert :cua_navigation in group_names
    end

    test "cua_navigation has exclusions" do
      groups = AgentScope.included_groups()

      cua_entry =
        Enum.find(groups, fn
          {:cua_navigation, _} -> true
          _ -> false
        end)

      assert {:cua_navigation, exclude: [:half_page_up, :half_page_down]} = cua_entry
    end
  end
end
