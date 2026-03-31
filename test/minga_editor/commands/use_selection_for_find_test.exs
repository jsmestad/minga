defmodule MingaEditor.Commands.UseSelectionForFindTest do
  @moduledoc """
  Tests for the :use_selection_for_find command (Cmd+E).
  """

  use Minga.Test.EditorCase, async: true

  describe "use_selection_for_find" do
    test "sets search pattern to word under cursor" do
      ctx = start_editor("hello world")

      state = editor_state(ctx)
      state = MingaEditor.Commands.execute(state, :use_selection_for_find)

      assert state.workspace.search.last_pattern == "hello"
      assert state.shell_state.status_msg =~ "hello"
    end

    test "sets forward search direction" do
      ctx = start_editor("hello world")

      state = editor_state(ctx)
      state = MingaEditor.Commands.execute(state, :use_selection_for_find)

      assert state.workspace.search.last_direction == :forward
    end
  end
end
