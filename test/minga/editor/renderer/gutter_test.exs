defmodule Minga.Editor.Renderer.GutterTest do
  @moduledoc """
  Tests for gutter rendering: modeline, cursor shape, cursor position, and
  screen cursor gutter offset.
  """

  use Minga.Test.EditorCase, async: true

  describe "modeline" do
    test "shows NORMAL mode on startup" do
      ctx = start_editor("hello")
      assert_mode(ctx, :normal)
    end

    test "shows filename in modeline" do
      ctx = start_editor("content", file_path: "/tmp/test_file.txt")
      assert_modeline_contains(ctx, "test_file.txt")
    end

    test "shows cursor position" do
      ctx = start_editor("hello\nworld")
      assert_modeline_contains(ctx, "1:1")
    end

    test "updates cursor position after movement" do
      ctx = start_editor("hello\nworld")

      send_key(ctx, ?j)
      send_key(ctx, ?l)
      send_key(ctx, ?l)

      assert_modeline_contains(ctx, "2:3")
    end

    test "shows INSERT mode after pressing i" do
      ctx = start_editor("hello")
      send_key(ctx, ?i)
      assert_mode(ctx, :insert)
    end

    test "shows VISUAL mode after pressing v" do
      ctx = start_editor("hello")
      send_key(ctx, ?v)
      assert_mode(ctx, :visual)
    end

    test "returns to NORMAL mode after Esc from insert" do
      ctx = start_editor("hello")
      send_key(ctx, ?i)
      assert_mode(ctx, :insert)
      send_key(ctx, 27)
      assert_mode(ctx, :normal)
    end

    test "shows dirty indicator after editing" do
      ctx = start_editor("hello")

      send_key(ctx, ?i)
      send_key(ctx, ?x)
      send_key(ctx, 27)

      assert_modeline_contains(ctx, "●")
    end
  end

  describe "cursor shape" do
    test "block cursor in normal mode" do
      ctx = start_editor("hello")
      assert cursor_shape(ctx) == :block
    end

    test "beam cursor in insert mode" do
      ctx = start_editor("hello")
      send_key(ctx, ?i)
      assert cursor_shape(ctx) == :beam
    end

    test "block cursor in visual mode" do
      ctx = start_editor("hello")
      send_key(ctx, ?v)
      assert cursor_shape(ctx) == :block
    end

    test "restores block cursor when leaving insert mode" do
      ctx = start_editor("hello")
      send_key(ctx, ?i)
      assert cursor_shape(ctx) == :beam
      send_key(ctx, 27)
      assert cursor_shape(ctx) == :block
    end
  end

  describe "screen cursor position" do
    @gutter_w 3

    test "cursor starts at gutter offset" do
      ctx = start_editor("hello\nworld")
      assert screen_cursor(ctx) == {0, @gutter_w}
    end

    test "cursor follows hjkl movement with gutter offset" do
      ctx = start_editor("hello\nworld")

      send_key(ctx, ?l)
      send_key(ctx, ?l)
      assert screen_cursor(ctx) == {0, @gutter_w + 2}

      send_key(ctx, ?j)
      assert screen_cursor(ctx) == {1, @gutter_w + 2}
    end
  end
end
