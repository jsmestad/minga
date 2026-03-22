defmodule Minga.Editor.Renderer.MinibufferTest do
  @moduledoc """
  Tests for minibuffer rendering: command input, search prompt, status
  messages, and cursor placement in command mode.
  """

  use Minga.Test.EditorCase, async: true

  describe "command mode / minibuffer" do
    test "shows colon and typed command in minibuffer" do
      ctx = start_editor("hello")

      send_key_sync(ctx, ?:)
      send_key_sync(ctx, ?w)
      send_key_sync(ctx, ?q)

      assert_minibuffer_contains(ctx, ":wq")
    end

    test "shows COMMAND mode in modeline" do
      ctx = start_editor("hello")
      send_key_sync(ctx, ?:)
      assert_mode(ctx, :command)
    end

    test "minibuffer clears after Esc" do
      ctx = start_editor("hello")

      send_key_sync(ctx, ?:)
      send_key_sync(ctx, ?w)
      send_key_sync(ctx, 27)

      assert_mode(ctx, :normal)
      mb = minibuffer(ctx)
      refute String.contains?(mb, ":w")
    end

    test "cursor moves to minibuffer in command mode" do
      ctx = start_editor("hello")

      send_key_sync(ctx, ?:)
      send_key_sync(ctx, ?q)

      {cursor_row, cursor_col} = screen_cursor(ctx)
      assert cursor_row == ctx.height - 1
      assert cursor_col == 2
    end
  end
end
