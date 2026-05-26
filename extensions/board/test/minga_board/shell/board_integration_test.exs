defmodule MingaBoard.ShellIntegrationTest do
  @moduledoc """
  Integration tests for Shell.Board with a real Editor GenServer.

  Verifies the Board renders visibly and the toggle command works
  end-to-end through the headless port.
  """
  # Mutates global command/keymap/shell registries for end-to-end extension binding coverage.
  use Minga.Test.EditorCase, async: false

  @source {:extension, :minga_board}

  setup do
    :ok = Minga.Command.Registry.unregister_source(@source)
    :ok = Minga.Keymap.Active.unregister_source(@source)
    :ok = MingaEditor.Shell.Registry.unregister_source(@source)
    :ok = MingaBoard.Feature.register_contributions()

    :ok =
      Minga.Command.Registry.register(
        Minga.Command.Registry,
        @source,
        :toggle_board,
        "Toggle The Board view",
        &MingaBoard.Commands.toggle/1
      )

    :ok =
      Minga.Keymap.Active.bind(
        Minga.Keymap.Active,
        :normal,
        "SPC t b",
        :toggle_board,
        "Toggle The Board",
        source: @source
      )

    on_exit(fn ->
      :ok = Minga.Command.Registry.unregister_source(@source)
      :ok = Minga.Keymap.Active.unregister_source(@source)
      :ok = MingaEditor.Shell.Registry.unregister_source(@source)
    end)

    :ok
  end

  describe "Board grid rendering" do
    test "Board shell renders card grid with You card" do
      ctx = start_editor("", shell: :board)

      state = editor_state(ctx)
      assert state.shell == MingaBoard.Shell
      assert MingaBoard.Shell.State.card_count(state.shell_state) == 1

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
      assert state.shell == MingaBoard.Shell
    end

    test "toggle_board switches back from Board to Traditional" do
      ctx = start_editor("hello world", shell: :board)

      state = editor_state(ctx)
      assert state.shell == MingaBoard.Shell

      # Execute the command directly because the Board grid consumes
      # unmodified keys, so SPC leader doesn't work from grid view.
      :sys.replace_state(ctx.editor, fn state ->
        MingaEditor.Commands.execute(state, :toggle_board)
      end)

      state = editor_state(ctx)
      assert state.shell == MingaEditor.Shell.Traditional
    end
  end
end
