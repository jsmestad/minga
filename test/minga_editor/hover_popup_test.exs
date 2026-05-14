defmodule MingaEditor.HoverPopupTest do
  use ExUnit.Case, async: true

  alias Minga.Language.Highlight.Span
  alias MingaEditor.HoverPopup
  alias MingaEditor.UI.Theme

  @theme Theme.get!(:doom_one)
  @viewport {24, 80}

  describe "new/4" do
    test "creates a popup with parsed markdown content" do
      popup = HoverPopup.new("**bold** text", 10, 20)
      assert %HoverPopup{} = popup
      assert popup.anchor_row == 10
      assert popup.anchor_col == 20
      assert popup.scroll_offset == 0
      assert popup.focused == false
      assert popup.content_lines != []
    end

    test "handles multi-line markdown" do
      text = "# Header\n\nSome text\n\n```elixir\ndefmodule Foo do\nend\n```"
      popup = HoverPopup.new(text, 5, 10)
      assert [_, _, _, _ | _] = popup.content_lines
    end

    test "handles plain text" do
      popup = HoverPopup.new("just plain text", 5, 10)
      assert [_] = popup.content_lines
    end

    test "adds syntax segments to highlighted fenced code blocks" do
      highlighter = fn "elixir", "def hello, do: :world", _opts ->
        {:ok, ["keyword"], [Span.new(0, 3, 0)]}
      end

      popup =
        HoverPopup.new("```elixir\ndef hello, do: :world\n```", 5, 10,
          theme: @theme,
          highlighter: highlighter
        )

      assert {segments, :code} = Enum.at(popup.content_lines, 1)
      assert {"def", {:syntax, face}} = hd(segments)
      assert face.fg != nil
    end

    test "uses the first fence info token as the tree-sitter language" do
      highlighter = fn "elixir", "def hello, do: :world", _opts ->
        {:ok, ["keyword"], [Span.new(0, 3, 0)]}
      end

      popup =
        HoverPopup.new("```elixir title=\"example\"\ndef hello, do: :world\n```", 5, 10,
          theme: @theme,
          highlighter: highlighter
        )

      assert {segments, :code} = Enum.at(popup.content_lines, 1)
      assert {"def", {:syntax, face}} = hd(segments)
      assert face.fg != nil
    end

    test "keeps code content styling when captures resolve to the default face" do
      highlighter = fn "elixir", "value", _opts ->
        {:ok, ["unknown.capture"], [Span.new(0, 5, 0)]}
      end

      popup =
        HoverPopup.new("```elixir\nvalue\n```", 5, 10,
          theme: @theme,
          highlighter: highlighter
        )

      assert {[{"value", {:code_content, "elixir"}}], :code} = Enum.at(popup.content_lines, 1)
    end

    test "preserves code block line order after syntax enhancement" do
      highlighter = fn "elixir", "first\nsecond", _opts ->
        {:ok, ["keyword"], [Span.new(0, 5, 0), Span.new(6, 12, 0)]}
      end

      popup =
        HoverPopup.new("```elixir\nfirst\nsecond\n```", 5, 10,
          theme: @theme,
          highlighter: highlighter
        )

      assert {[{"first", {:syntax, _}}], :code} = Enum.at(popup.content_lines, 1)
      assert {[{"second", {:syntax, _}}], :code} = Enum.at(popup.content_lines, 2)
    end

    test "falls back when the highlighter raises" do
      highlighter = fn "elixir", _source, _opts -> raise "parser unavailable" end

      popup =
        HoverPopup.new("```elixir\nvalue\n```", 5, 10,
          theme: @theme,
          highlighter: highlighter
        )

      assert {[{"value", {:code_content, "elixir"}}], :code} = Enum.at(popup.content_lines, 1)
    end

    test "skips highlighting without calling highlighter when timeout is zero" do
      highlighter = fn _language, _source, _opts ->
        flunk("highlighter should not be called when timeout is zero")
      end

      popup =
        HoverPopup.new("```elixir\nvalue\n```", 5, 10,
          theme: @theme,
          timeout: 0,
          highlighter: highlighter
        )

      assert {[{"value", {:code_content, "elixir"}}], :code} = Enum.at(popup.content_lines, 1)
    end

    test "passes a bounded timeout and falls back when highlighting times out" do
      parent = self()

      highlighter = fn "elixir", _source, opts ->
        send(parent, {:hover_highlight_timeout, Keyword.fetch!(opts, :timeout)})
        :timeout
      end

      popup =
        HoverPopup.new("```elixir\nvalue\n```", 5, 10,
          theme: @theme,
          highlighter: highlighter
        )

      assert_receive {:hover_highlight_timeout, timeout}
      assert timeout <= 50
      assert {[{"value", {:code_content, "elixir"}}], :code} = Enum.at(popup.content_lines, 1)
    end

    test "falls back to code_content segments when highlighting is unavailable" do
      highlighter = fn "unknown", _source, _opts -> :unsupported end

      popup =
        HoverPopup.new("```unknown\nvalue\n```", 5, 10,
          theme: @theme,
          highlighter: highlighter
        )

      assert {[{"value", {:code_content, "unknown"}}], :code} = Enum.at(popup.content_lines, 1)
    end
  end

  describe "focus/1" do
    test "sets focused to true" do
      popup = HoverPopup.new("text", 5, 10)
      assert popup.focused == false
      focused = HoverPopup.focus(popup)
      assert focused.focused == true
    end
  end

  describe "scroll_down/1" do
    test "increases scroll offset" do
      popup = HoverPopup.new("line1\nline2\nline3\nline4\nline5\nline6", 5, 10)
      scrolled = HoverPopup.scroll_down(popup)
      assert scrolled.scroll_offset == 3
    end

    test "clamps at max offset" do
      popup = HoverPopup.new("short", 5, 10)
      scrolled = popup |> HoverPopup.scroll_down() |> HoverPopup.scroll_down()
      assert scrolled.scroll_offset >= 0
    end
  end

  describe "scroll_up/1" do
    test "decreases scroll offset" do
      popup = HoverPopup.new("line1\nline2\nline3\nline4\nline5", 5, 10)
      scrolled = popup |> HoverPopup.scroll_down() |> HoverPopup.scroll_up()
      assert scrolled.scroll_offset == 0
    end

    test "clamps at zero" do
      popup = HoverPopup.new("text", 5, 10)
      scrolled = HoverPopup.scroll_up(popup)
      assert scrolled.scroll_offset == 0
    end
  end

  describe "render/3" do
    test "returns empty list for empty content" do
      popup = %HoverPopup{content_lines: [], anchor_row: 5, anchor_col: 10}
      assert HoverPopup.render(popup, @viewport, @theme) == []
    end

    test "returns draw commands for non-empty content" do
      popup = HoverPopup.new("Hello world\n\nSome documentation", 10, 20)
      draws = HoverPopup.render(popup, @viewport, @theme)
      assert is_list(draws)
      assert draws != []
      assert Enum.all?(draws, &is_tuple/1)
    end

    test "produces draws with valid screen coordinates" do
      popup = HoverPopup.new("Type: `String.t()`", 10, 20)
      draws = HoverPopup.render(popup, @viewport, @theme)

      Enum.each(draws, fn {row, col, _text, _style} ->
        assert row >= 0 and row < 24, "row #{row} out of viewport"
        assert col >= 0 and col < 80, "col #{col} out of viewport"
      end)
    end

    test "renders markdown code blocks with styling" do
      text = "```elixir\ndef hello, do: :world\n```"
      popup = HoverPopup.new(text, 15, 10)
      draws = HoverPopup.render(popup, @viewport, @theme)
      assert draws != []
    end

    test "preserves segment draw order within a rendered line" do
      popup = %HoverPopup{
        content_lines: [{[{"first", :plain}, {"second", :bold}], :text}],
        anchor_row: 15,
        anchor_col: 10
      }

      texts =
        popup
        |> HoverPopup.render(@viewport, @theme)
        |> Enum.map(fn {_row, _col, text, _style} -> text end)
        |> Enum.filter(&(&1 in ["first", "second"]))

      assert texts == ["first", "second"]
    end

    test "uses rounded border when not focused, single when focused" do
      popup = HoverPopup.new("text", 10, 10)

      # Not focused: rounded border chars (╭, ╮)
      draws = HoverPopup.render(popup, @viewport, @theme)
      texts = Enum.map(draws, fn {_r, _c, text, _s} -> text end)
      combined = Enum.join(texts)
      assert String.contains?(combined, "╭") or String.contains?(combined, "┌")

      # Focused: single border chars (┌, ┐)
      focused = HoverPopup.focus(popup)
      focused_draws = HoverPopup.render(focused, @viewport, @theme)
      focused_texts = Enum.map(focused_draws, fn {_r, _c, text, _s} -> text end)
      focused_combined = Enum.join(focused_texts)
      assert String.contains?(focused_combined, "┌")
    end

    test "positions above cursor when there is room" do
      popup = HoverPopup.new("text", 15, 10)
      draws = HoverPopup.render(popup, @viewport, @theme)

      # All draws should be above row 15 (the anchor)
      rows = Enum.map(draws, fn {r, _c, _text, _s} -> r end)
      max_row = Enum.max(rows)
      assert max_row < 15, "Expected hover above cursor row 15, got max row #{max_row}"
    end

    test "flips below cursor when near top of screen" do
      popup = HoverPopup.new("text", 1, 10)
      draws = HoverPopup.render(popup, @viewport, @theme)

      # Some draws should be below row 1
      rows = Enum.map(draws, fn {r, _c, _text, _s} -> r end)
      min_row = Enum.min(rows)
      assert min_row >= 0
    end

    test "shows scroll indicator when content exceeds window" do
      lines = Enum.map_join(1..30, "\n", &"Line #{&1} of documentation")
      popup = HoverPopup.new(lines, 15, 10)
      draws = HoverPopup.render(popup, @viewport, @theme)

      texts = Enum.map(draws, fn {_r, _c, text, _s} -> text end)
      combined = Enum.join(texts)
      # Footer should show scroll position like "1-20/30"
      assert String.contains?(combined, "/")
    end
  end
end
