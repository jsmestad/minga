defmodule MingaEditor.Commands.SearchLeaderTest do
  @moduledoc """
  Layer 0/1 command-state tests for search leader commands.

  These commands only transform EditorState, so they do not need a live Editor GenServer.
  """

  use ExUnit.Case, async: true

  import MingaEditor.CommandStateHelpers

  describe "Layer 0/1 command state: search_buffer" do
    test "transitions to search mode with forward direction" do
      state = start_buffer("hello world") |> command_state()

      state = MingaEditor.Commands.execute(state, :search_buffer)

      assert state.workspace.editing.mode == :search
      assert state.workspace.editing.mode_state.direction == :forward
    end
  end

  describe "Layer 0/1 command state: search_and_replace" do
    test "transitions to command mode with %s/ prefix" do
      state = start_buffer("hello world") |> command_state()

      state = MingaEditor.Commands.execute(state, :search_and_replace)

      assert state.workspace.editing.mode == :command
      assert state.workspace.editing.mode_state.input == "%s/"
    end
  end
end
