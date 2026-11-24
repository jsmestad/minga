defmodule Minga.Keymap.Scope.AgentDiffReviewKeysTest do
  @moduledoc "Verifies the Agent scope binds Diff Review keys for each editing model only while a staged review has focus."
  use ExUnit.Case, async: true

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Scope.Agent, as: AgentScope

  @shift 0x01
  @ctrl 0x02
  @alt 0x04
  @cmd 0x08

  @reviewing [agent_diff_review: true]

  # Each CUA chord, the action whose hint names it (nil for an alias without
  # its own hint), and the command it must run.
  @cua_chords [
    {{57_353, @alt}, :next_hunk, :agent_next_code_block},
    {{0xF701, @alt}, nil, :agent_next_code_block},
    {{57_370, 0}, nil, :agent_next_code_block},
    {{57_352, @alt}, :previous_hunk, :agent_prev_code_block},
    {{0xF700, @alt}, nil, :agent_prev_code_block},
    {{57_370, @shift}, nil, :agent_prev_code_block},
    {{13, @cmd}, :accept_hunk, :agent_accept_hunk},
    {{13, @ctrl}, :accept_hunk, :agent_accept_hunk},
    {{127, @cmd}, :reject_hunk, :agent_reject_hunk},
    {{127, @ctrl}, :reject_hunk, :agent_reject_hunk},
    {{13, @cmd + @shift}, :accept_all, :agent_accept_all_hunks},
    {{13, @ctrl + @shift}, :accept_all, :agent_accept_all_hunks},
    {{127, @cmd + @shift}, :reject_all, :agent_reject_all_hunks},
    {{127, @ctrl + @shift}, :reject_all, :agent_reject_all_hunks}
  ]

  @vim_keys [
    {[{?], 0}, {?c, 0}], :next_hunk, :agent_next_code_block},
    {[{?[, 0}, {?c, 0}], :previous_hunk, :agent_prev_code_block},
    {[{?y, 0}], :accept_hunk, :agent_accept_hunk},
    {[{?x, 0}], :reject_hunk, :agent_reject_hunk},
    {[{?Y, 0}], :accept_all, :agent_accept_all_hunks},
    {[{?X, 0}], :reject_all, :agent_reject_all_hunks}
  ]

  describe "CUA" do
    test "each review chord runs its command only while a staged Diff Review has focus" do
      reviewing = AgentScope.keymap(:cua, @reviewing)

      for {key, _action, command} <- @cua_chords do
        assert Bindings.lookup(reviewing, key) == {:command, command}, inspect(key)

        for context <- [[], [agent_diff_review: false]] do
          assert Bindings.lookup(AgentScope.keymap(:cua, context), key) == :not_found,
                 "#{inspect(key)} leaked outside Diff Review"
        end
      end
    end

    test "review chords leave the CUA Agent bindings and printable keys alone" do
      reviewing = AgentScope.keymap(:cua, @reviewing)

      for {key, command} <- [
            {{13, 0}, :agent_focus_or_submit},
            {{127, 0}, :agent_input_backspace},
            {{57_352, 0}, :agent_input_up},
            {{13, @alt}, :agent_insert_newline},
            {{9, 0}, :agent_switch_focus}
          ] do
        assert Bindings.lookup(reviewing, key) == {:command, command}
      end

      for char <- [?y, ?x, ?Y, ?X] do
        assert Bindings.lookup(reviewing, {char, 0}) == :not_found
      end
    end

    test "every CUA hint names a chord that runs the action while reviewing" do
      reviewing = AgentScope.keymap(:cua, @reviewing)

      for key_set <- [:cua_cmd, :cua_ctrl], {_key, action, command} <- @cua_chords, action do
        hint = AgentScope.diff_review_key_hint(action, key_set)
        assert Bindings.lookup(reviewing, hint_key(hint)) == {:command, command}, hint
      end

      assert AgentScope.diff_review_key_hint(:accept_hunk, :cua_cmd) == "Cmd+Enter"
      assert AgentScope.diff_review_key_hint(:reject_hunk, :cua_ctrl) == "Ctrl+Backspace"
      assert AgentScope.diff_review_key_hint(:next_hunk, :cua_cmd) == "Alt+Down"
    end
  end

  describe "Vim" do
    test "y, x, Y and X decide hunks only while a staged Diff Review has focus" do
      reviewing = AgentScope.keymap(:normal, @reviewing)
      chat = AgentScope.keymap(:normal, [])

      for {keys, action, command} <- @vim_keys do
        assert lookup_sequence(reviewing, keys) == {:command, command}

        assert AgentScope.diff_review_key_hint(action, :vim) ==
                 keys |> Bindings.format_sequence() |> String.replace(" ", "")
      end

      assert Bindings.lookup(chat, {?y, 0}) == {:command, :agent_copy_code_block}
      assert Bindings.lookup(chat, {?Y, 0}) == {:command, :agent_copy_message}
      assert Bindings.lookup(chat, {?x, 0}) == :not_found
      # Bracket navigation keeps its other targets while reviewing.
      assert lookup_sequence(reviewing, [{?], 0}, {?f, 0}]) == {:command, :timeline_next_file}
    end

    test "the composer tries never bind Diff Review keys" do
      for vim_state <- [:insert, :input_normal], {[key | _], _action, _command} <- @vim_keys do
        refute match?(
                 {:command, command}
                 when command in [:agent_accept_hunk, :agent_reject_hunk],
                 Bindings.lookup(AgentScope.keymap(vim_state, @reviewing), key)
               )
      end
    end
  end

  test "the help group lists every action with the hint for the key set" do
    for key_set <- [:vim, :cua_cmd, :cua_ctrl] do
      {"Diff Review", rows} = AgentScope.diff_review_help_group(key_set)

      assert Enum.map(rows, &elem(&1, 0)) ==
               Enum.map(
                 [
                   :next_hunk,
                   :previous_hunk,
                   :accept_hunk,
                   :reject_hunk,
                   :accept_all,
                   :reject_all
                 ],
                 &AgentScope.diff_review_key_hint(&1, key_set)
               )
    end
  end

  test "the key set follows the editing model and whether the frontend can send Cmd" do
    assert AgentScope.diff_review_key_set(:vim, true) == :vim
    assert AgentScope.diff_review_key_set(:vim, false) == :vim
    assert AgentScope.diff_review_key_set(:cua, true) == :cua_cmd
    assert AgentScope.diff_review_key_set(:cua, false) == :cua_ctrl
  end

  # Reads a hint such as "Cmd+Shift+Enter" back into the key tuple it names.
  defp hint_key(hint) do
    {key, modifiers} = hint |> String.split("+") |> List.pop_at(-1)

    mods =
      Enum.reduce(modifiers, 0, fn
        "Shift", acc -> acc + @shift
        "Ctrl", acc -> acc + @ctrl
        "Alt", acc -> acc + @alt
        "Cmd", acc -> acc + @cmd
      end)

    codepoint =
      case key do
        "Enter" -> 13
        "Backspace" -> 127
        "Up" -> 57_352
        "Down" -> 57_353
      end

    {codepoint, mods}
  end

  defp lookup_sequence(trie, [key]), do: Bindings.lookup(trie, key)

  defp lookup_sequence(trie, [key | rest]) do
    {:prefix, node} = Bindings.lookup(trie, key)
    lookup_sequence(node, rest)
  end
end
