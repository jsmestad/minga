defmodule Minga.Editor.MacroIntegrationTest do
  @moduledoc """
  Integration tests for keystroke macros via the headless harness.
  """

  use Minga.Test.EditorCase, async: true

  describe "recording and replaying macros" do
    test "qa...q records, @a replays" do
      ctx = start_editor("aaa\nbbb\nccc")

      # Record macro: qa (start), x (delete char), j (move down), q (stop)
      send_keys(ctx, "qaxjq")

      # First line should have "aa" (deleted first char)
      assert_row_contains(ctx, 0, "aa")
      # Cursor should be on line 1
      assert buffer_cursor(ctx) == {1, 0}

      # Replay: @a
      send_keys(ctx, "@a")

      # Second line should have "bb" (deleted first char)
      assert_row_contains(ctx, 1, "bb")
      # Cursor should be on line 2
      assert buffer_cursor(ctx) == {2, 0}
    end

    test "macro with count prefix: 2@a" do
      ctx = start_editor("1xxx\n2xxx\n3xxx\n4xxx\n5xxx")

      # Record macro: delete first char, move down
      send_keys(ctx, "qaxjq")

      # Replay twice with count
      send_keys(ctx, "2@a")

      # Lines 0, 1, 2 should have first char deleted
      content = buffer_content(ctx)
      lines = String.split(content, "\n")
      assert Enum.at(lines, 0) == "xxx"
      assert Enum.at(lines, 1) == "xxx"
      assert Enum.at(lines, 2) == "xxx"
      # Lines 3, 4 should be untouched
      assert Enum.at(lines, 3) == "4xxx"
      assert Enum.at(lines, 4) == "5xxx"
    end

    test "@@ replays last macro" do
      ctx = start_editor("aaa\nbbb\nccc")

      # Record macro into register a
      send_keys(ctx, "qaxjq")

      # Replay with @@
      send_keys(ctx, "@@")

      content = buffer_content(ctx)
      lines = String.split(content, "\n")
      assert Enum.at(lines, 0) == "aa"
      assert Enum.at(lines, 1) == "bb"
    end

    test "recording indicator shows in modeline" do
      ctx = start_editor("hello")

      # Start recording into register a
      send_keys(ctx, "qa")

      ml = modeline(ctx)
      assert String.contains?(ml, "recording @a")

      # Stop recording
      send_keys(ctx, "q")

      ml = modeline(ctx)
      refute String.contains?(ml, "recording")
    end

    test "different registers store independent macros" do
      ctx = start_editor("aaa\nbbb\nccc")

      # Record into a: delete char
      send_keys(ctx, "qaxq")
      # Record into b: move down
      send_keys(ctx, "qbjq")

      # Go to start
      send_keys(ctx, "gg0")

      # Replay b (move down), then a (delete char)
      send_keys(ctx, "@b@a")

      content = buffer_content(ctx)
      lines = String.split(content, "\n")
      # Line 0: "aa" (from first qa recording)
      assert Enum.at(lines, 0) == "aa"
      # Line 1: "bb" (deleted by @a after @b moved down)
      assert Enum.at(lines, 1) == "bb"
    end

    test "replaying unrecorded register shows error" do
      ctx = start_editor("hello")
      send_keys(ctx, "@z")
      mb = minibuffer(ctx)
      assert String.contains?(mb, "No macro in register @z")
    end

    test "@@ with no previous macro shows error" do
      ctx = start_editor("hello")
      send_keys(ctx, "@@")
      mb = minibuffer(ctx)
      assert String.contains?(mb, "No previous macro")
    end
  end

  describe "macros don't break dot repeat" do
    test "dot repeat works after macro recording" do
      ctx = start_editor("aaa\nbbb\nccc")

      # Record a macro (doesn't matter what)
      send_keys(ctx, "qajq")

      # Now do a normal edit: delete first char
      send_keys(ctx, "gg0x")
      assert buffer_content(ctx) |> String.split("\n") |> List.first() == "aa"

      # Dot repeat should repeat the x (delete char)
      send_keys(ctx, ".")
      assert buffer_content(ctx) |> String.split("\n") |> List.first() == "a"
    end
  end
end
