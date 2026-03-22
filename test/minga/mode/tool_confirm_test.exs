defmodule Minga.Mode.ToolConfirmTest do
  use ExUnit.Case, async: true

  alias Minga.Mode
  alias Minga.Mode.ToolConfirm
  alias Minga.Mode.ToolConfirmState

  @none 0

  describe "handle_key/2" do
    test "y on single pending tool returns execute_then_transition to normal" do
      state = %ToolConfirmState{pending: [:pyright], declined: MapSet.new()}

      assert {:execute_then_transition, [{:tool_confirm_accept, :pyright}], :normal, _state} =
               ToolConfirm.handle_key({?y, @none}, state)
    end

    test "y advances to next pending tool when more remain" do
      state = %ToolConfirmState{pending: [:pyright, :prettier], declined: MapSet.new()}

      assert {:execute, [{:tool_confirm_accept, :pyright}], new_state} =
               ToolConfirm.handle_key({?y, @none}, state)

      assert new_state.current == 1
    end

    test "n on single pending tool transitions to normal" do
      state = %ToolConfirmState{pending: [:pyright], declined: MapSet.new()}

      assert {:execute_then_transition, [{:tool_confirm_decline, :pyright}], :normal, new_state} =
               ToolConfirm.handle_key({?n, @none}, state)

      assert MapSet.member?(new_state.declined, :pyright)
    end

    test "n advances to next pending tool when more remain" do
      state = %ToolConfirmState{pending: [:pyright, :prettier], declined: MapSet.new()}

      assert {:execute, [{:tool_confirm_decline, :pyright}], new_state} =
               ToolConfirm.handle_key({?n, @none}, state)

      assert new_state.current == 1
      assert MapSet.member?(new_state.declined, :pyright)
    end

    test "escape dismisses all remaining and transitions to normal" do
      state = %ToolConfirmState{
        pending: [:pyright, :prettier, :black],
        current: 1,
        declined: MapSet.new()
      }

      assert {:execute_then_transition, [{:tool_confirm_dismiss, declined}], :normal, _state} =
               ToolConfirm.handle_key({27, @none}, state)

      # Should decline :prettier (current) and :black (remaining)
      assert MapSet.member?(declined, :prettier)
      assert MapSet.member?(declined, :black)
      # :pyright was already handled (current=1 means we're past index 0)
      refute MapSet.member?(declined, :pyright)
    end

    test "other keys are ignored" do
      state = %ToolConfirmState{pending: [:pyright], declined: MapSet.new()}

      assert {:continue, ^state} = ToolConfirm.handle_key({?x, @none}, state)
    end

    test "sequential accept then decline" do
      state = %ToolConfirmState{pending: [:pyright, :prettier, :black], declined: MapSet.new()}

      # Accept first
      {:execute, [{:tool_confirm_accept, :pyright}], state} =
        ToolConfirm.handle_key({?y, @none}, state)

      assert state.current == 1

      # Decline second
      {:execute, [{:tool_confirm_decline, :prettier}], state} =
        ToolConfirm.handle_key({?n, @none}, state)

      assert state.current == 2
      assert MapSet.member?(state.declined, :prettier)

      # Accept third (last one, transitions to normal)
      assert {:execute_then_transition, [{:tool_confirm_accept, :black}], :normal, _} =
               ToolConfirm.handle_key({?y, @none}, state)
    end
  end

  describe "Mode.process/3 integration" do
    test "y dispatches tool_confirm_accept command" do
      state = %ToolConfirmState{pending: [:pyright], declined: MapSet.new()}

      {mode, commands, _new_state} = Mode.process(:tool_confirm, {?y, @none}, state)

      assert mode == :normal
      assert [{:tool_confirm_accept, :pyright}] = commands
    end

    test "n dispatches tool_confirm_decline command" do
      state = %ToolConfirmState{pending: [:pyright], declined: MapSet.new()}

      {mode, commands, _new_state} = Mode.process(:tool_confirm, {?n, @none}, state)

      assert mode == :normal
      assert [{:tool_confirm_decline, :pyright}] = commands
    end
  end

  describe "Mode.display/2" do
    test "shows tool name and prompt" do
      state = %ToolConfirmState{pending: [:pyright], declined: MapSet.new()}
      display = Mode.display(:tool_confirm, state)

      assert String.contains?(display, "not found")
      assert String.contains?(display, "[y/n]")
    end
  end
end
