defmodule MingaEditor.Commands.SearchLeaderTest do
  use Minga.Test.EditorCase, async: true

  describe "search_buffer" do
    test "transitions to search mode with forward direction" do
      ctx = start_editor("hello world")

      state = editor_state(ctx)
      state = MingaEditor.Commands.execute(state, :search_buffer)

      assert state.workspace.editing.mode == :search
      assert state.workspace.editing.mode_state.direction == :forward
    end
  end

  describe "search_and_replace" do
    test "transitions to command mode with %s/ prefix" do
      ctx = start_editor("hello world")

      state = editor_state(ctx)
      state = MingaEditor.Commands.execute(state, :search_and_replace)

      assert state.workspace.editing.mode == :command
      assert state.workspace.editing.mode_state.input == "%s/"
    end
  end
end
