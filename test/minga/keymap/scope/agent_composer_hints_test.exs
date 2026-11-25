defmodule Minga.Keymap.Scope.AgentComposerHintsTest do
  @moduledoc "The composer's key hints name keys the Agent scope binds, for each focus, frontend and turn."
  use ExUnit.Case, async: true

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Scope.Agent, as: AgentScope

  @enter 13
  @escape 27
  @alt 0x04
  @cmd 0x08

  # Each hint's keys as the scope state and key sequence that runs them.
  @hint_keys %{
    "⌘↩" => [{@enter, @cmd}],
    "⌥↩" => [{@enter, @alt}],
    "↩" => [{@enter, 0}],
    "⌘." => [{?., @cmd}],
    "esc" => [{@escape, 0}],
    "i" => [{?i, 0}],
    "⌃C" => [{?c, 0x02}]
  }

  # Hints made of more than one press, checked on their own below.
  @sequences ["esc ↩", "SPC a s"]

  test "the hints for each focus, frontend and turn" do
    assert AgentScope.composer_key_hints(:insert, native_gui: true) ==
             [{"⌘↩", "send"}, {"⌥↩", "queue"}, {"esc", "normal"}]

    assert AgentScope.composer_key_hints(:insert, native_gui: false, working: true) ==
             [{"esc ↩", "send"}, {"⌥↩", "queue"}, {"⌃C", "stop"}, {"esc", "normal"}]

    assert AgentScope.composer_key_hints(:normal, native_gui: false, working: true) ==
             [{"↩", "send"}, {"SPC a s", "stop"}, {"i", "insert"}]

    # ⌃C copies with desktop shortcuts, so the terminal hints no stop key there.
    assert AgentScope.composer_key_hints(:cua, native_gui: false, working: true) ==
             [{"↩", "send"}, {"⌥↩", "new line"}]

    assert AgentScope.composer_key_hints(:normal, native_gui: true, working: true) ==
             [{"↩", "send"}, {"⌘.", "stop"}, {"i", "insert"}]

    assert AgentScope.composer_key_hints(:normal, stopped: true) ==
             [{"↩", "continue"}, {"i", "insert"}]

    assert AgentScope.composer_key_hints(:cua, native_gui: true, working: true) ==
             [{"↩", "send"}, {"⌥↩", "new line"}, {"⌘.", "stop"}]
  end

  test "a failed start's remedy owns ↩ in Normal, so no hint offers to send" do
    for native <- [true, false], working <- [true, false] do
      opts = [native_gui: native, working: working, remedy: true]

      assert AgentScope.composer_key_hints(:insert, opts) == [
               {"↩", "new line"},
               {"esc", "normal"}
             ]

      assert AgentScope.composer_key_hints(:normal, opts) == []
      assert AgentScope.composer_key_hints(:cua, opts) == []
    end
  end

  test "every single-key hint is bound in the state it is shown in" do
    for {focus, state} <- [insert: :insert, normal: :input_normal, cua: :cua],
        native <- [true, false],
        working <- [true, false],
        {keys, _action} <-
          AgentScope.composer_key_hints(focus, native_gui: native, working: working),
        keys not in @sequences,
        sequence = Map.fetch!(@hint_keys, keys),
        # `i` and `esc` in the composer's Normal mode are Vim's own keys, handled by the Mode FSM.
        not (focus == :normal and keys in ["i", "esc"]) do
      trie = AgentScope.keymap(state, [])

      assert match?({:command, _}, Bindings.lookup(trie, hd(sequence))),
             "#{keys} is shown in #{focus} but #{state} binds nothing for it"
    end
  end

  test "a leader hint is shown only where the leader is reached, never where letters type text" do
    for focus <- [:insert, :cua], native <- [true, false], working <- [true, false] do
      keys =
        for {keys, _} <-
              AgentScope.composer_key_hints(focus, native_gui: native, working: working),
            do: keys

      refute "SPC a s" in keys, "#{focus} must not hint SPC a s, where SPC types a space"
    end
  end

  test "a stop hint runs a stop where it is shown" do
    stops = [:agent_abort, :agent_ctrl_c]

    for {focus, state} <- [insert: :insert, normal: :input_normal, cua: :cua],
        native <- [true, false],
        {keys, "stop"} <- AgentScope.composer_key_hints(focus, native_gui: native, working: true),
        keys != "SPC a s" do
      trie = AgentScope.keymap(state, [])
      [key] = Map.fetch!(@hint_keys, keys)
      assert {:command, command} = Bindings.lookup(trie, key)
      assert command in stops, "#{keys} is hinted to stop in #{focus} but runs #{command}"
    end
  end
end
