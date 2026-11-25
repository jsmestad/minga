defmodule Minga.Keymap.Scope.AgentScopeSharedGroupsTest do
  @moduledoc "Verifies the agent scope uses shared groups correctly."
  use ExUnit.Case, async: true

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Scope.Agent, as: AgentScope

  @ctrl 0x02
  @alt 0x04
  @cmd 0x08

  describe "insert mode trie" do
    setup do
      {:ok, trie: AgentScope.keymap(:insert, [])}
    end

    test "Ctrl+C from ctrl_agent_common group", %{trie: trie} do
      assert {:command, :agent_ctrl_c} = Bindings.lookup(trie, {?c, @ctrl})
    end

    test "control keys that edit text where you type are not bound", %{trie: trie} do
      for key <- [?u, ?d, ?l, ?s, ?q, ?w, ?a, ?e, ?h] do
        assert Bindings.lookup(trie, {key, @ctrl}) == :not_found, "⌃#{<<key>>} is bound"
      end
    end

    test "Enter adds a newline; Cmd+Enter sends, Alt+Enter queues, Cmd+. stops", %{trie: trie} do
      assert {:command, :agent_insert_newline} = Bindings.lookup(trie, {13, 0})
      assert {:command, :agent_submit_or_newline} = Bindings.lookup(trie, {13, @cmd})
      assert {:command, :agent_queue_follow_up} = Bindings.lookup(trie, {13, @alt})
      assert {:command, :agent_abort} = Bindings.lookup(trie, {?., @cmd})
    end

    test "Ctrl+Enter and Alt+Up no longer queue or dequeue", %{trie: trie} do
      assert Bindings.lookup(trie, {13, @ctrl}) == :not_found
      assert Bindings.lookup(trie, {0xF700, @alt}) == :not_found
      assert Bindings.lookup(trie, {57_352, @alt}) == :not_found
    end

    test "the other newline variants from the shared group remain", %{trie: trie} do
      # Shift+Enter
      assert {:command, :agent_insert_newline} = Bindings.lookup(trie, {13, 0x01})
      # Ctrl+J
      assert {:command, :agent_insert_newline} = Bindings.lookup(trie, {?j, @ctrl})
      # Raw LF
      assert {:command, :agent_insert_newline} = Bindings.lookup(trie, {0x0A, 0})
    end

    test "Escape and Backspace keep their bindings", %{trie: trie} do
      assert {:command, :agent_input_to_normal} = Bindings.lookup(trie, {27, 0})
      assert {:command, :agent_input_backspace} = Bindings.lookup(trie, {127, 0})
    end
  end

  describe "input_normal mode trie" do
    setup do
      {:ok, trie: AgentScope.keymap(:input_normal, [])}
    end

    test "Enter and Cmd+Enter send and Cmd+. stops; Alt+Enter queues only while typing",
         %{trie: trie} do
      assert {:command, :agent_submit_or_newline} = Bindings.lookup(trie, {13, 0})
      assert {:command, :agent_submit_or_newline} = Bindings.lookup(trie, {13, @cmd})
      assert {:command, :agent_abort} = Bindings.lookup(trie, {?., @cmd})
      assert Bindings.lookup(trie, {13, @alt}) == :not_found
    end

    test "only Ctrl+C remains of the control keys", %{trie: trie} do
      assert {:command, :agent_ctrl_c} = Bindings.lookup(trie, {?c, @ctrl})

      for key <- [?d, ?u, ?l, ?s, ?q] do
        assert Bindings.lookup(trie, {key, @ctrl}) == :not_found, "⌃#{<<key>>} is bound"
      end
    end

    test "q is Vim's again; Escape returns to chat navigation", %{trie: trie} do
      assert Bindings.lookup(trie, {?q, 0}) == :not_found
      assert {:command, :agent_unfocus_input} = Bindings.lookup(trie, {27, 0})
    end
  end

  describe "chat navigation (normal) trie" do
    test "q closes the split, Cmd+. stops, Ctrl+L is gone" do
      trie = AgentScope.keymap(:normal, [])
      assert {:command, :agent_close} = Bindings.lookup(trie, {?q, 0})
      assert {:command, :agent_abort} = Bindings.lookup(trie, {?., @cmd})
      assert Bindings.lookup(trie, {?l, @ctrl}) == :not_found
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
