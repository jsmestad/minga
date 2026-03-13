defmodule Minga.Editor.MessagesBufferTest do
  @moduledoc """
  Tests for the *Messages* buffer and SPC b m.
  """

  use Minga.Test.EditorCase, async: true

  describe "*Messages* buffer" do
    test "SPC b m opens messages buffer in a popup split" do
      ctx = start_editor("hello")
      send_keys(ctx, "<SPC>bm")

      # The messages buffer opens as a popup split. Its modeline should be
      # visible on screen (not necessarily the last modeline row, since
      # the popup occupies the bottom portion).
      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "*Messages*")
    end

    test "messages buffer contains editor startup log" do
      ctx = start_editor("hello")
      send_keys(ctx, "<SPC>bm")

      # The messages buffer content appears in the popup split area.
      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "Editor started")
    end

    test "messages buffer shows [RO] indicator" do
      ctx = start_editor("hello")
      send_keys(ctx, "<SPC>bm")

      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "[RO]")
    end

    test "entering insert mode on messages buffer is blocked" do
      ctx = start_editor("hello")
      send_keys(ctx, "<SPC>bm")
      send_keys(ctx, "i")

      assert editor_mode(ctx) == :normal
      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "read-only")
    end

    test "SPC b m toggles the messages popup closed" do
      ctx = start_editor("hello")

      # Open the messages popup
      send_keys(ctx, "<SPC>bm")
      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "*Messages*")

      # Toggle it closed
      send_keys(ctx, "<SPC>bm")
      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      refute String.contains?(all_text, "*Messages*")
    end

    test "q dismisses the messages popup" do
      ctx = start_editor("hello")
      send_keys(ctx, "<SPC>bm")

      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      assert String.contains?(all_text, "*Messages*")

      # Press q to dismiss
      send_keys(ctx, "q")
      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")
      refute String.contains?(all_text, "*Messages*")
    end

    test "messages buffer is hidden from buffer picker" do
      ctx = start_editor("hello")

      send_keys(ctx, "<SPC>bb")
      screen = screen_text(ctx)
      all_text = Enum.join(screen, "\n")

      refute String.contains?(all_text, "*Messages*")
    end
  end
end
