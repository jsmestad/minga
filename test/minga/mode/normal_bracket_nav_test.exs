defmodule Minga.Mode.NormalBracketNavTest do
  @moduledoc """
  Tests for bracket-prefix navigation keys: ]f/[f, ]t/[t, ]a/[a.
  Also tests the = operator entry into operator-pending mode.
  Uses the prefix trie (no pending_bracket flags).
  """
  use ExUnit.Case, async: true

  alias Minga.Mode.Normal
  alias Minga.Mode.State, as: ModeState

  # Press ] or [ to enter prefix trie, returns the updated state.
  defp press_bracket(direction) do
    key = if direction == :next, do: {?], 0}, else: {?[, 0}
    {:continue, state} = Normal.handle_key(key, %ModeState{})
    state
  end

  # ── ]f / [f — function navigation ──────────────────────────────────────────

  describe "]f / [f — goto next/prev function" do
    test "]f emits goto_next_textobject for :function" do
      state = press_bracket(:next)

      assert {:execute, {:goto_next_textobject, :function}, _} =
               Normal.handle_key({?f, 0}, state)
    end

    test "[f emits goto_prev_textobject for :function" do
      state = press_bracket(:prev)

      assert {:execute, {:goto_prev_textobject, :function}, _} =
               Normal.handle_key({?f, 0}, state)
    end
  end

  # ── ]t / [t — type/class navigation ────────────────────────────────────────

  describe "]t / [t — goto next/prev class" do
    test "]t emits goto_next_textobject for :class" do
      state = press_bracket(:next)

      assert {:execute, {:goto_next_textobject, :class}, _} =
               Normal.handle_key({?t, 0}, state)
    end

    test "[t emits goto_prev_textobject for :class" do
      state = press_bracket(:prev)

      assert {:execute, {:goto_prev_textobject, :class}, _} =
               Normal.handle_key({?t, 0}, state)
    end
  end

  # ── ]a / [a — parameter navigation ─────────────────────────────────────────

  describe "]a / [a — goto next/prev parameter" do
    test "]a emits goto_next_textobject for :parameter" do
      state = press_bracket(:next)

      assert {:execute, {:goto_next_textobject, :parameter}, _} =
               Normal.handle_key({?a, 0}, state)
    end

    test "[a emits goto_prev_textobject for :parameter" do
      state = press_bracket(:prev)

      assert {:execute, {:goto_prev_textobject, :parameter}, _} =
               Normal.handle_key({?a, 0}, state)
    end
  end

  # ── Prefix state resets on dispatch ───────────────────────────────────────

  describe "prefix state resets on dispatch" do
    test "prefix_node is cleared after successful dispatch" do
      state = press_bracket(:next)

      {:execute, _, new_state} = Normal.handle_key({?f, 0}, state)
      assert new_state.prefix_node == nil
    end

    test "unknown second key cancels prefix" do
      state = press_bracket(:next)

      {:continue, new_state} = Normal.handle_key({?x, 0}, state)
      assert new_state.prefix_node == nil
    end
  end

  # ── `a` key disambiguation ─────────────────────────────────────────────────

  describe "`a` key disambiguation" do
    test "a with no prefix pending enters insert mode (append)" do
      state = %ModeState{}

      assert {:execute_then_transition, [:move_right], :insert, _} =
               Normal.handle_key({?a, 0}, state)
    end

    test "]a emits goto_next_textobject :parameter" do
      state = press_bracket(:next)

      assert {:execute, {:goto_next_textobject, :parameter}, _} =
               Normal.handle_key({?a, 0}, state)
    end
  end

  # ── = operator entry ──────────────────────────────────────────────────────

  describe "= operator" do
    test "= enters operator-pending with :reindent operator" do
      state = %ModeState{}

      assert {:transition, :operator_pending,
              %Minga.Mode.OperatorPendingState{operator: :reindent}} =
               Normal.handle_key({?=, 0}, state)
    end

    test "= passes count to operator-pending state" do
      state = %ModeState{count: 5}

      assert {:transition, :operator_pending,
              %Minga.Mode.OperatorPendingState{operator: :reindent, op_count: 5}} =
               Normal.handle_key({?=, 0}, state)
    end
  end
end
