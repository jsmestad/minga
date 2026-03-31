defmodule MingaEditor.Commands.SelectAllTest do
  @moduledoc """
  Tests for the :select_all command.
  """

  use Minga.Test.EditorCase, async: true

  describe "select_all" do
    test "enters visual line mode with full buffer selected" do
      ctx = start_editor("aaa\nbbb\nccc")

      send_keys_sync(ctx, "<Space>")
      # Cancel the leader mode (we just need normal mode for the test)
      send_key(ctx, 27)

      # Execute select_all via command registry
      state = editor_state(ctx)
      state = MingaEditor.Commands.execute(state, :select_all)

      assert Minga.Editing.mode(state) == :visual
      ms = MingaEditor.Editing.mode_state(state)
      assert ms.visual_anchor == {0, 0}
      assert ms.visual_type == :line
    end

    test "works with single-line buffer" do
      ctx = start_editor("hello")

      state = editor_state(ctx)
      state = MingaEditor.Commands.execute(state, :select_all)

      assert Minga.Editing.mode(state) == :visual
      ms = MingaEditor.Editing.mode_state(state)
      assert ms.visual_anchor == {0, 0}
    end
  end
end
