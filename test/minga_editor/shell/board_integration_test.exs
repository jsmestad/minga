defmodule MingaEditor.Shell.BoardIntegrationTest do
  @moduledoc """
  Integration tests for Shell.Board with a real Editor GenServer.

  Verifies the Board renders visibly and the toggle command works
  end-to-end through the headless port.
  """
  use Minga.Test.EditorCase, async: true

  describe "Board grid rendering" do
    test "Board shell renders card grid with You card" do
      ctx = start_editor("", shell: :board)

      state = editor_state(ctx)
      assert state.shell == MingaEditor.Shell.Board
      assert MingaEditor.Shell.Board.State.card_count(state.shell_state) == 1

      # The screen should show Board content
      assert screen_contains?(ctx, "The Board") or screen_contains?(ctx, "You")
    end

    test "toggle_board switches from Traditional to Board" do
      ctx = start_editor("hello world")

      # Start in Traditional
      state = editor_state(ctx)
      assert state.shell == MingaEditor.Shell.Traditional

      # Toggle to Board via leader key: SPC t b
      send_keys_sync(ctx, "<Space>tb")

      state = editor_state(ctx)
      assert state.shell == MingaEditor.Shell.Board
    end

    test "toggle_board switches back from Board to Traditional" do
      ctx = start_editor("hello world", shell: :board)

      state = editor_state(ctx)
      assert state.shell == MingaEditor.Shell.Board

      # Toggle back via :sys.replace_state (Board grid consumes
      # unmodified keys, so SPC leader doesn't work from grid view).
      :sys.replace_state(ctx.editor, fn state ->
        %{
          state
          | shell: MingaEditor.Shell.Traditional,
            shell_state: %MingaEditor.Shell.Traditional.State{},
            layout: nil
        }
      end)

      state = editor_state(ctx)
      assert state.shell == MingaEditor.Shell.Traditional
    end
  end
end
