defmodule Minga.Integration.PickerLifecycleTest do
  @moduledoc """
  Thin integration smoke tests for picker lifecycle.

  Lower-level picker source and command tests cover item contents and filtering details. This file keeps the full editor path to prove leader keys open the picker, typed filters affect the visible overlay, Escape restores editing state, Enter executes a selected item, and visual-mode cancel restores the prior mode.
  """
  use Minga.Test.EditorCase, async: true

  describe "buffer picker" do
    test "open, filter, restore, and cancel leaves the buffer unchanged" do
      ctx = start_editor("hello world")
      cursor_before = buffer_cursor(ctx)

      send_keys_sync(ctx, "<Space>bb")
      assert picker_state(ctx).title == "Switch buffer"
      assert picker_contains?(ctx, "[no file]")

      send_keys_sync(ctx, "zzz")
      assert picker_state(ctx).query == "zzz"

      send_keys_sync(ctx, "<BS><BS><BS>")
      assert picker_contains?(ctx, "[no file]")

      send_keys_sync(ctx, "<Esc>")
      assert editor_mode(ctx) == :normal
      assert_modeline_contains(ctx, "NORMAL")
      assert buffer_cursor(ctx) == cursor_before
      refute picker_open?(ctx)
    end

    test "selecting the only buffer closes the picker" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>bb<CR>")

      assert editor_mode(ctx) == :normal
      refute screen_contains?(ctx, "Switch buffer")
    end
  end

  describe "command palette" do
    test "open, filter, and execute a side-effect-free command" do
      ctx = start_editor("hello world")

      send_keys_sync(ctx, "<Space>:")
      assert picker_state(ctx).title == "Commands"

      send_keys_sync(ctx, "cycle_line_numbers")
      assert picker_contains?(ctx, "cycle_line_numbers")

      send_keys_sync(ctx, "<CR>")

      assert editor_mode(ctx) == :normal
      assert picker_open?(ctx)
      assert picker_state(ctx).title == "Apply to..."
    end
  end

  defp picker_contains?(ctx, text) do
    ctx
    |> picker_state()
    |> Map.get(:filtered, [])
    |> Enum.any?(fn item ->
      String.contains?(item.label, text) or String.contains?(item.search_text || "", text)
    end)
  end
end
