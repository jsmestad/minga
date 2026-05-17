defmodule MingaEditor.Commands.SelectAllTest do
  @moduledoc """
  Layer 0/1 command-state tests for the :select_all command.

  The observable contract is the selected buffer range and visual state, so a live Editor GenServer is unnecessary.
  """

  use ExUnit.Case, async: true

  import MingaEditor.CommandStateHelpers

  alias Minga.Buffer.Process, as: BufferProcess

  describe "Layer 0/1 command state: select_all" do
    test "enters visual line mode with full buffer selected" do
      buffer = start_buffer("aaa\nbbb\nccc")
      state = command_state(buffer)

      state = MingaEditor.Commands.execute(state, :select_all)

      assert state.workspace.editing.mode == :visual
      assert state.workspace.editing.mode_state.visual_anchor == {0, 0}
      assert state.workspace.editing.mode_state.visual_type == :line
      assert BufferProcess.cursor(buffer) == {2, 2}
    end

    test "works with single-line buffer" do
      buffer = start_buffer("hello")
      state = command_state(buffer)

      state = MingaEditor.Commands.execute(state, :select_all)

      assert state.workspace.editing.mode == :visual
      assert state.workspace.editing.mode_state.visual_anchor == {0, 0}
      assert BufferProcess.cursor(buffer) == {0, 4}
    end
  end
end
