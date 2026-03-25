defmodule Minga.Editor.Commands.UseSelectionForFindTest do
  @moduledoc """
  Tests for the :use_selection_for_find command (Cmd+E).
  """

  use Minga.Test.EditorCase, async: true

  describe "use_selection_for_find" do
    test "sets search pattern to word under cursor" do
      ctx = start_editor("hello world")

      state = editor_state(ctx)
      state = Minga.Editor.Commands.execute(state, :use_selection_for_find)

      assert state.search.last_pattern == "hello"
      assert state.status_msg =~ "hello"
    end

    test "sets forward search direction" do
      ctx = start_editor("hello world")

      state = editor_state(ctx)
      state = Minga.Editor.Commands.execute(state, :use_selection_for_find)

      assert state.search.last_direction == :forward
    end
  end
end
