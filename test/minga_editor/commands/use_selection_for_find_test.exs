defmodule MingaEditor.Commands.UseSelectionForFindTest do
  @moduledoc """
  Layer 0/1 command-state tests for the :use_selection_for_find command.

  The command reads the active buffer snapshot and updates search/status state directly, so it does not need a live Editor GenServer.
  """

  use ExUnit.Case, async: true

  import MingaEditor.CommandStateHelpers

  describe "Layer 0/1 command state: use_selection_for_find" do
    test "sets search pattern to word under cursor" do
      state = start_buffer("hello world") |> command_state()

      state = MingaEditor.Commands.execute(state, :use_selection_for_find)

      assert state.workspace.search.last_pattern == "hello"
      assert state.shell_state.status_msg =~ "hello"
    end

    test "sets forward search direction" do
      state = start_buffer("hello world") |> command_state()

      state = MingaEditor.Commands.execute(state, :use_selection_for_find)

      assert state.workspace.search.last_direction == :forward
    end
  end
end
