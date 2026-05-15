defmodule Minga.Integration.ToggleInvisibleTest do
  @moduledoc "Integration tests for toggling invisible characters via SPC t i."
  use Minga.Test.EditorCase, async: true

  alias Minga.Buffer.Process, as: BufferProcess

  describe "SPC t i toggles invisible characters" do
    test "toggles show_invisible option on the buffer" do
      ctx = start_editor("hello")

      assert BufferProcess.get_option(ctx.buffer, :show_invisible) == false

      send_keys_sync(ctx, "<SPC>ti")
      assert BufferProcess.get_option(ctx.buffer, :show_invisible) == true

      send_keys_sync(ctx, "<SPC>ti")
      assert BufferProcess.get_option(ctx.buffer, :show_invisible) == false
    end

    test "trailing whitespace renders as dots when enabled" do
      ctx = start_editor("hello   ")

      send_keys_sync(ctx, "<SPC>ti")

      row = screen_row(ctx, 1)
      assert row =~ "hello···"
    end

    test "tab characters render as arrow when enabled" do
      ctx = start_editor("\thello")

      send_keys_sync(ctx, "<SPC>ti")

      row = screen_row(ctx, 1)
      assert row =~ "→"
      assert row =~ "hello"
    end

    test "invisible markers disappear when toggled off" do
      ctx = start_editor("hello   ")

      send_keys_sync(ctx, "<SPC>ti")
      row = screen_row(ctx, 1)
      assert row =~ "·"

      send_keys_sync(ctx, "<SPC>ti")
      row = screen_row(ctx, 1)
      refute row =~ "·"
    end
  end
end
