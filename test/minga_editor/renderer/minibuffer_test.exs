defmodule MingaEditor.Renderer.MinibufferTest do
  @moduledoc """
  Tests for minibuffer rendering: command input, search prompt, status
  messages, and cursor placement in command mode.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Core.Unicode
  alias MingaEditor.Renderer.Minibuffer
  alias MingaEditor.UI.Theme

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

    test "status messages render as a full-width bold banner" do
      theme = Theme.get!(:doom_one)

      {row, col, text, face} =
        Minibuffer.render(%{shell_state: %{status_msg: "Saved"}, theme: theme}, 8, 24)

      assert row == 8
      assert col == 0
      assert String.starts_with?(text, " ◆  Saved")
      assert Unicode.display_width(text) == 24
      assert face.bg == theme.modeline.info_bg
      assert face.bold == true
    end

    test "status banner also fits wide graphemes exactly" do
      theme = Theme.get!(:doom_one)

      {row, col, text, face} =
        Minibuffer.render(%{shell_state: %{status_msg: "界界界"}, theme: theme}, 8, 16)

      assert row == 8
      assert col == 0
      assert Unicode.display_width(text) == 16
      assert String.contains?(text, "界界界")
      assert face.bg == theme.modeline.info_bg
      assert face.bold == true
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
