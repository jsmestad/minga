defmodule Minga.Mode.NormalBracketNavTest do
  @moduledoc """
  Tests for bracket-prefix navigation keys: ]f/[f, ]t/[t, ]a/[a.
  Also tests the = operator entry into operator-pending mode.
  """
  use ExUnit.Case, async: true

  alias Minga.Mode.Normal
  alias Minga.Mode.State, as: ModeState

  defp state_with_bracket(direction) do
    %ModeState{pending_bracket: direction}
  end

  # ── ]f / [f — function navigation ──────────────────────────────────────────

  describe "]f / [f — goto next/prev function" do
    test "]f emits goto_next_textobject for :function" do
      state = state_with_bracket(:next)

      assert {:execute, {:goto_next_textobject, :function}, %ModeState{pending_bracket: nil}} =
               Normal.handle_key({?f, 0}, state)
    end

    test "[f emits goto_prev_textobject for :function" do
      state = state_with_bracket(:prev)

      assert {:execute, {:goto_prev_textobject, :function}, %ModeState{pending_bracket: nil}} =
               Normal.handle_key({?f, 0}, state)
    end
  end

  # ── ]t / [t — type/class navigation ────────────────────────────────────────

  describe "]t / [t — goto next/prev class" do
    test "]t emits goto_next_textobject for :class" do
      state = state_with_bracket(:next)

      assert {:execute, {:goto_next_textobject, :class}, %ModeState{pending_bracket: nil}} =
               Normal.handle_key({?t, 0}, state)
    end

    test "[t emits goto_prev_textobject for :class" do
      state = state_with_bracket(:prev)

      assert {:execute, {:goto_prev_textobject, :class}, %ModeState{pending_bracket: nil}} =
               Normal.handle_key({?t, 0}, state)
    end
  end

  # ── ]a / [a — parameter navigation ─────────────────────────────────────────

  describe "]a / [a — goto next/prev parameter" do
    test "]a emits goto_next_textobject for :parameter" do
      state = state_with_bracket(:next)

      assert {:execute, {:goto_next_textobject, :parameter}, %ModeState{pending_bracket: nil}} =
               Normal.handle_key({?a, 0}, state)
    end

    test "[a emits goto_prev_textobject for :parameter" do
      state = state_with_bracket(:prev)

      assert {:execute, {:goto_prev_textobject, :parameter}, %ModeState{pending_bracket: nil}} =
               Normal.handle_key({?a, 0}, state)
    end
  end

  # ── Bracket state resets on dispatch ───────────────────────────────────────

  describe "bracket state resets on dispatch" do
    test "pending_bracket is cleared after successful dispatch" do
      state = state_with_bracket(:next)

      {:execute, _, new_state} = Normal.handle_key({?f, 0}, state)
      assert new_state.pending_bracket == nil
    end
  end

  # ── `a` key guarded by pending_bracket ─────────────────────────────────────

  describe "`a` key disambiguation" do
    test "a with no bracket pending enters insert mode (append)" do
      state = %ModeState{pending_bracket: nil}

      assert {:execute_then_transition, [:move_right], :insert, _} =
               Normal.handle_key({?a, 0}, state)
    end

    test "a with :next bracket pending emits goto_next_textobject :parameter" do
      state = state_with_bracket(:next)

      assert {:execute, {:goto_next_textobject, :parameter}, _} =
               Normal.handle_key({?a, 0}, state)
    end
  end

  # ── = operator entry ──────────────────────────────────────────────────────

  describe "= operator" do
    test "= enters operator-pending with :reindent operator" do
      state = %ModeState{pending_bracket: nil}

      assert {:transition, :operator_pending,
              %Minga.Mode.OperatorPendingState{operator: :reindent}} =
               Normal.handle_key({?=, 0}, state)
    end

    test "= passes count to operator-pending state" do
      state = %ModeState{count: 5, pending_bracket: nil}

      assert {:transition, :operator_pending,
              %Minga.Mode.OperatorPendingState{operator: :reindent, op_count: 5}} =
               Normal.handle_key({?=, 0}, state)
    end
  end
end
