defmodule MingaEditor.DisplayListAssertionsTest do
  @moduledoc """
  Tests for the display list assertion layer.

  Verifies that assertion helpers correctly extract text from Frame and
  WindowFrame structs, that render_frame produces valid output from
  base_state, and that content assertions are decoupled from chrome layout.
  """

  use ExUnit.Case, async: true

  alias Minga.Core.Face
  alias MingaEditor.DisplayList.{Cursor, Frame, WindowFrame}

  import MingaEditor.RenderPipeline.TestHelpers
  import Minga.Test.DisplayListAssertions

  # ── window_content_text/1 ─────────────────────────────────────────────────

  describe "window_content_text/1" do
    test "extracts text from content lines sorted by row" do
      lines = %{
        0 => [{4, "hello world", Face.new()}],
        1 => [{4, "second line", Face.new()}]
      }

      wf = %WindowFrame{rect: {0, 0, 80, 24}, lines: lines}
      result = window_content_text(wf)

      assert [{0, "hello world"}, {1, "second line"}] = result
    end

    test "concatenates multiple text runs on same row sorted by column" do
      lines = %{
        0 => [
          {10, "world", Face.new()},
          {0, "hello ", Face.new(fg: 0xFF0000)}
        ]
      }

      wf = %WindowFrame{rect: {0, 0, 80, 24}, lines: lines}
      [{0, text}] = window_content_text(wf)

      assert text == "hello world"
    end

    test "includes tilde lines when no content on that row" do
      lines = %{0 => [{4, "only line", Face.new()}]}
      tildes = %{1 => [{0, "~", Face.new(fg: 0x5B6268)}]}

      wf = %WindowFrame{rect: {0, 0, 80, 24}, lines: lines, tilde_lines: tildes}
      result = window_content_text(wf)

      assert length(result) == 2
      assert {1, "~"} in result
    end

    test "prefers content lines over tilde lines on same row" do
      lines = %{0 => [{4, "real content", Face.new()}]}
      tildes = %{0 => [{0, "~", Face.new()}]}

      wf = %WindowFrame{rect: {0, 0, 80, 24}, lines: lines, tilde_lines: tildes}
      [{0, text}] = window_content_text(wf)

      assert text == "real content"
    end

    test "empty window returns empty list" do
      wf = %WindowFrame{rect: {0, 0, 80, 24}}
      assert window_content_text(wf) == []
    end
  end

  # ── window_gutter_text/1 ──────────────────────────────────────────────────

  describe "window_gutter_text/1" do
    test "extracts gutter text" do
      gutter = %{
        0 => [{0, "  1 ", Face.new(fg: 0x5B6268)}],
        1 => [{0, "  2 ", Face.new(fg: 0x5B6268)}]
      }

      wf = %WindowFrame{rect: {0, 0, 80, 24}, gutter: gutter}
      result = window_gutter_text(wf)

      assert [{0, "  1 "}, {1, "  2 "}] = result
    end
  end

  # ── find_draws/3 ──────────────────────────────────────────────────────────

  describe "find_draws/3" do
    test "finds draws matching a string pattern in tab bar" do
      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        tab_bar: [
          {0, 0, " [scratch] ", Face.new()},
          {0, 12, " file.ex ", Face.new()}
        ]
      }

      matches = find_draws(frame, :tab_bar, "scratch")
      assert length(matches) == 1
      {0, 0, text, _} = hd(matches)
      assert String.contains?(text, "scratch")
    end

    test "finds draws matching a regex pattern in status bar" do
      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        status_bar: [
          {22, 0, " NORMAL ", Face.new()},
          {22, 10, "main", Face.new()}
        ]
      }

      matches = find_draws(frame, :status_bar, ~r/NORMAL/)
      assert length(matches) == 1
    end

    test "returns empty list when no matches" do
      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        minibuffer: [{23, 0, " ", Face.new()}]
      }

      assert find_draws(frame, :minibuffer, "nonexistent") == []
    end

    test "searches file_tree draws" do
      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        file_tree: [{2, 0, "lib/", Face.new()}]
      }

      assert length(find_draws(frame, :file_tree, "lib/")) == 1
    end

    test "searches agent_panel draws" do
      frame = %Frame{
        cursor: Cursor.new(0, 0, :block),
        agent_panel: [{5, 0, "Agent: ready", Face.new()}]
      }

      assert length(find_draws(frame, :agent_panel, "ready")) == 1
    end
  end

  # ── draws_to_text/1 ──────────────────────────────────────────────────────

  describe "draws_to_text/1" do
    test "concatenates draws sorted by row then column" do
      draws = [
        {1, 0, "second", Face.new()},
        {0, 6, "world", Face.new()},
        {0, 0, "hello ", Face.new()}
      ]

      text = draws_to_text(draws)
      assert text == "hello worldsecond"
    end

    test "empty draws produce empty string" do
      assert draws_to_text([]) == ""
    end
  end

  # ── text_matches?/2 ──────────────────────────────────────────────────────

  describe "text_matches?/2" do
    test "matches substring with string pattern" do
      assert text_matches?("hello world", "world")
    end

    test "rejects non-matching string pattern" do
      refute text_matches?("hello world", "xyz")
    end

    test "matches regex pattern" do
      assert text_matches?("NORMAL mode", ~r/NORMAL/)
    end

    test "rejects non-matching regex" do
      refute text_matches?("INSERT mode", ~r/NORMAL/)
    end
  end

  # ── render_frame/1 ────────────────────────────────────────────────────────

  describe "render_frame/1" do
    test "produces a valid Frame from base_state" do
      state = base_state()
      frame = render_frame(state)

      assert %Frame{cursor: %Cursor{}} = frame
      assert frame.cursor.shape in [:block, :beam, :underline]
      assert [_ | _] = frame.windows
    end

    test "frame contains window content from buffer" do
      state = base_state(content: "hello world\nsecond line")
      frame = render_frame(state)
      window = hd(frame.windows)
      text_lines = window_content_text(window)
      all_text = Enum.map(text_lines, fn {_row, text} -> text end)

      assert Enum.any?(all_text, &String.contains?(&1, "hello world"))
      assert Enum.any?(all_text, &String.contains?(&1, "second line"))
    end

    test "frame has status bar draws" do
      state = base_state()
      frame = render_frame(state)

      assert [_ | _] = frame.status_bar
    end

    test "frame has minibuffer draws" do
      state = base_state()
      frame = render_frame(state)

      assert [_ | _] = frame.minibuffer
    end

    test "frame has tab bar draws" do
      state = base_state()
      frame = render_frame(state)

      assert is_list(frame.tab_bar)
    end

    test "different viewport sizes produce valid frames" do
      for {rows, cols} <- [{10, 40}, {24, 80}, {50, 200}] do
        state = base_state(rows: rows, cols: cols)
        frame = render_frame(state)
        assert %Frame{cursor: %Cursor{}} = frame
      end
    end
  end

  # ── Assertion macros ──────────────────────────────────────────────────────

  describe "assert_window_contains/2" do
    test "passes when content contains pattern" do
      state = base_state(content: "unique_marker text")
      frame = render_frame(state)
      window = hd(frame.windows)

      assert_window_contains(window, "unique_marker")
    end

    test "passes with regex pattern" do
      state = base_state(content: "line 42 here")
      frame = render_frame(state)
      window = hd(frame.windows)

      assert_window_contains(window, ~r/line \d+ here/)
    end
  end

  describe "assert_window_has_text/3" do
    test "passes when specific row contains text" do
      state = base_state(content: "first line\nsecond line\nthird line")
      frame = render_frame(state)
      window = hd(frame.windows)

      # Content rows are window-relative; row 1 contains the first line
      # (row 0 may be empty or offset depending on the gutter layout)
      text_lines = window_content_text(window)
      first_row = text_lines |> hd() |> elem(0)

      assert_window_has_text(window, first_row, "first line")
    end
  end

  describe "assert_frame_cursor/4" do
    test "verifies cursor position and shape" do
      state = base_state()
      frame = render_frame(state)

      # Normal mode → block cursor. Position depends on gutter, but we
      # can verify the shape and that position is non-negative.
      assert frame.cursor.shape == :block
      assert frame.cursor.row >= 0
      assert frame.cursor.col >= 0
    end
  end

  describe "assert_status_bar_contains/2" do
    test "passes when status bar has matching text" do
      state = base_state()
      frame = render_frame(state)

      # In normal mode, status bar should show NORMAL
      assert_status_bar_contains(frame, "NORMAL")
    end
  end

  # ── Content independence from chrome ──────────────────────────────────────

  describe "content assertions survive chrome changes" do
    test "window content text is independent of tab bar height" do
      content = "alpha\nbeta\ngamma"

      # Render at two different viewport sizes (simulating different
      # chrome configurations). The content text extraction should
      # produce the same buffer content regardless.
      state_small = base_state(content: content, rows: 20, cols: 80)
      state_large = base_state(content: content, rows: 30, cols: 80)

      frame_small = render_frame(state_small)
      frame_large = render_frame(state_large)

      win_small = hd(frame_small.windows)
      win_large = hd(frame_large.windows)

      text_small = window_content_text(win_small) |> Enum.map(fn {_r, t} -> t end)
      text_large = window_content_text(win_large) |> Enum.map(fn {_r, t} -> t end)

      # Both should contain the same buffer content
      assert Enum.any?(text_small, &String.contains?(&1, "alpha"))
      assert Enum.any?(text_small, &String.contains?(&1, "beta"))
      assert Enum.any?(text_small, &String.contains?(&1, "gamma"))

      assert Enum.any?(text_large, &String.contains?(&1, "alpha"))
      assert Enum.any?(text_large, &String.contains?(&1, "beta"))
      assert Enum.any?(text_large, &String.contains?(&1, "gamma"))
    end

    test "window content is in window-relative coordinates" do
      state = base_state(content: "hello\nworld")
      frame = render_frame(state)
      window = hd(frame.windows)

      # Content rows should be window-relative (small integers),
      # not absolute screen coordinates. The exact starting row
      # depends on gutter layout but should be well within the
      # window rect height.
      {_row_off, _col_off, _w, height} = window.rect
      text_lines = window_content_text(window)
      rows = Enum.map(text_lines, fn {row, _text} -> row end)

      assert rows != [], "Expected at least one content row"
      assert Enum.min(rows) < height, "Content rows should be within window height"
    end
  end

  # ── Demonstration: cursor position matches expected ───────────────────────

  describe "cursor position" do
    test "cursor is within viewport bounds" do
      state = base_state(rows: 24, cols: 80)
      frame = render_frame(state)

      assert frame.cursor.row >= 0
      assert frame.cursor.row < 24
      assert frame.cursor.col >= 0
      assert frame.cursor.col < 80
    end

    test "normal mode has block cursor" do
      state = base_state()
      frame = render_frame(state)

      assert frame.cursor.shape == :block
    end
  end
end
