defmodule Minga.Keymap.Scope.AgentStartRemedyTest do
  @moduledoc "Verifies the Agent scope binds a failed start's remedy key only while the tab offers it."
  use ExUnit.Case, async: true

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.KeyParser
  alias Minga.Keymap.Scope.Agent, as: AgentScope

  @remedies [:retry, :set_up_provider]

  test "r runs the remedy in chat navigation for either remedy, and only while one is offered" do
    for remedy <- @remedies do
      assert Bindings.lookup(AgentScope.keymap(:normal, agent_start_remedy: remedy), {?r, 0}) ==
               {:command, :agent_start_remedy}
    end

    for context <- [[], [agent_start_remedy: nil]] do
      assert Bindings.lookup(AgentScope.keymap(:normal, context), {?r, 0}) == :not_found
    end
  end

  test "the session switcher on s is never shadowed, even during a setup failure" do
    for context <- [[], [agent_start_remedy: :retry], [agent_start_remedy: :set_up_provider]] do
      assert Bindings.lookup(AgentScope.keymap(:normal, context), {?s, 0}) ==
               {:command, :agent_session_switcher}
    end
  end

  test "the insert and input-normal tries never bind r or s" do
    for vim_state <- [:insert, :input_normal], remedy <- @remedies, key <- [?r, ?s] do
      assert Bindings.lookup(AgentScope.keymap(vim_state, agent_start_remedy: remedy), {key, 0}) ==
               :not_found
    end
  end

  test "Enter submits from the composer only while a remedy is offered, so slash commands still run" do
    for remedy <- @remedies do
      trie = AgentScope.start_remedy_keymap(:composer, agent_start_remedy: remedy)
      assert Bindings.lookup(trie, {13, 0}) == {:command, :agent_submit_or_newline}
    end

    assert Bindings.lookup(AgentScope.start_remedy_keymap(:composer, []), {13, 0}) == :not_found
  end

  test "CUA binds Enter to submit during a failed start, from chat and composer alike" do
    assert Bindings.lookup(AgentScope.keymap(:cua, []), {13, 0}) ==
             {:command, :agent_focus_or_submit}

    for remedy <- @remedies do
      trie = AgentScope.keymap(:cua, agent_start_remedy: remedy)
      assert Bindings.lookup(trie, {13, 0}) == {:command, :agent_submit_or_newline}
      # Printable keys still type in the CUA composer.
      assert Bindings.lookup(trie, {?r, 0}) == :not_found
    end
  end

  test "the key hint names the key bound at each focus" do
    for {focus, hint, key, command} <- [
          {:chat, "r", "r", :agent_start_remedy},
          {:composer, "Enter", "RET", :agent_submit_or_newline},
          {:cua, "Enter", "RET", :agent_submit_or_newline}
        ] do
      assert AgentScope.start_remedy_key_hint(focus) == hint
      [bound] = KeyParser.parse!(key)
      trie = AgentScope.start_remedy_keymap(focus, agent_start_remedy: :retry)
      assert Bindings.lookup(trie, bound) == {:command, command}
    end
  end
end
