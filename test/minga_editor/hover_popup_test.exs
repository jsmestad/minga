defmodule MingaEditor.HoverPopupTest do
  use ExUnit.Case, async: true

  alias Minga.Language.Highlight.Span
  alias MingaEditor.HoverPopup
  alias MingaEditor.HoverPopup.Builder
  alias MingaEditor.HoverPopup.Presenter
  alias MingaEditor.UI.Theme

  @theme Theme.get!(:doom_one)
  @viewport {24, 80}

  describe "new/4" do
    test "creates a popup with parsed markdown content" do
      popup = Builder.new("**bold** text", 10, 20)
      assert %HoverPopup{} = popup
      assert popup.anchor_row == 10
      assert popup.anchor_col == 20
      assert popup.scroll_offset == 0
      assert popup.focused == false
      assert popup.content_lines != []
    end

    test "lifecycle owner parses without invoking presentation services" do
      highlighter = fn _language, _source, _opts -> flunk("owner invoked highlighter") end
      popup = HoverPopup.new("```elixir\nvalue\n```", 5, 10, highlighter: highlighter)

      assert %HoverPopup{} = popup
      assert popup.content_lines != []
    end

    test "handles multi-line markdown" do
      text = "# Header\n\nSome text\n\n```elixir\ndefmodule Foo do\nend\n```"
      popup = Builder.new(text, 5, 10)
      assert [_, _, _, _ | _] = popup.content_lines
    end

    test "handles plain text" do
      popup = Builder.new("just plain text", 5, 10)
      assert [_] = popup.content_lines
    end

    test "adds syntax segments to highlighted fenced code blocks" do
      highlighter = fn "elixir", "def hello, do: :world", _opts ->
        {:ok, ["keyword"], [Span.new(0, 3, 0)]}
      end

      popup =
        Builder.new("```elixir\ndef hello, do: :world\n```", 5, 10,
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
        Builder.new("```elixir title=\"example\"\ndef hello, do: :world\n```", 5, 10,
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
        Builder.new("```elixir\nvalue\n```", 5, 10,
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
        Builder.new("```elixir\nfirst\nsecond\n```", 5, 10,
          theme: @theme,
          highlighter: highlighter
        )

      assert {[{"first", {:syntax, _}}], :code} = Enum.at(popup.content_lines, 1)
      assert {[{"second", {:syntax, _}}], :code} = Enum.at(popup.content_lines, 2)
    end

    test "falls back when the highlighter raises" do
      highlighter = fn "elixir", _source, _opts -> raise "parser unavailable" end

      popup =
        Builder.new("```elixir\nvalue\n```", 5, 10,
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
        Builder.new("```elixir\nvalue\n```", 5, 10,
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
        Builder.new("```elixir\nvalue\n```", 5, 10,
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
        Builder.new("```unknown\nvalue\n```", 5, 10,
          theme: @theme,
          highlighter: highlighter
        )

      assert {[{"value", {:code_content, "unknown"}}], :code} = Enum.at(popup.content_lines, 1)
    end
  end

  describe "focus/1" do
    test "sets focused to true" do
      popup = Builder.new("text", 5, 10)
      assert popup.focused == false
      focused = HoverPopup.focus(popup)
      assert focused.focused == true
    end
  end

  describe "scroll_down/1" do
    test "increases scroll offset" do
      popup = Builder.new("line1\nline2\nline3\nline4\nline5\nline6", 5, 10)
      scrolled = HoverPopup.scroll_down(popup)
      assert scrolled.scroll_offset == 3
    end

    test "clamps at max offset" do
      popup = Builder.new("short", 5, 10)
      scrolled = popup |> HoverPopup.scroll_down() |> HoverPopup.scroll_down()
      assert scrolled.scroll_offset >= 0
    end
  end

  describe "scroll_up/1" do
    test "decreases scroll offset" do
      popup = Builder.new("line1\nline2\nline3\nline4\nline5", 5, 10)
      scrolled = popup |> HoverPopup.scroll_down() |> HoverPopup.scroll_up()
      assert scrolled.scroll_offset == 0
    end

    test "clamps at zero" do
      popup = Builder.new("text", 5, 10)
      scrolled = HoverPopup.scroll_up(popup)
      assert scrolled.scroll_offset == 0
    end
  end

  describe "box/2" do
    # The cell-grid `render/3` painter was removed in #2311; the hover popup
    # renders natively via the 0x81 GUI opcode. `box/2` is the live surface that
    # resolves the popup's placement rect for the FocusTree/SurfaceRegistry.
    test "returns nil for empty content" do
      popup = %HoverPopup{content_lines: [], anchor_row: 5, anchor_col: 10}
      assert Presenter.box(popup, @viewport) == nil
    end

    test "returns the exact conservative rect for simple markdown" do
      popup = Builder.new("Returns the **value**.", 2, 6)

      assert Presenter.box(popup, @viewport) == {3, 6, 32, 3}
    end

    test "places tall content below near the upper viewport without covering anchor row" do
      popup = Builder.new(tall_hover_text(), 7, 10)

      assert Presenter.box(popup, @viewport) == {8, 10, 32, 16}
    end

    test "places tall content above near the lower viewport without covering anchor row" do
      popup = Builder.new(tall_hover_text(), 18, 10)

      assert Presenter.box(popup, @viewport) == {0, 10, 32, 18}
    end

    test "focused and unfocused popups have identical geometry" do
      popup = Builder.new("Returns the **value**.", 2, 6)

      assert Presenter.box(popup, @viewport) ==
               Presenter.box(HoverPopup.focus(popup), @viewport)
    end
  end

  describe "with_open_action/2 and open_action_name/1" do
    test "accepts an open_session action (with and without a tool_call_id) and exposes it" do
      popup =
        "x"
        |> Builder.new(1, 1)
        |> HoverPopup.with_open_action({:open_session, "sess-123", "tc1"})

      assert popup.open_action == {:open_session, "sess-123", "tc1"}
      assert HoverPopup.open_action?(popup)
      assert HoverPopup.open_action_name({:open_session, "sess-123", "tc1"}) == "open_session"

      # tool_call_id is optional (plain resume).
      no_tc = HoverPopup.with_open_action(Builder.new("x", 1, 1), {:open_session, "s", nil})
      assert no_tc.open_action == {:open_session, "s", nil}
    end

    test "still accepts goto_location and atom actions" do
      goto =
        HoverPopup.with_open_action(Builder.new("x", 1, 1), {:goto_location, "f.ex", 0, 0})

      assert goto.open_action == {:goto_location, "f.ex", 0, 0}

      atom = HoverPopup.with_open_action(Builder.new("x", 1, 1), :some_command)
      assert atom.open_action == :some_command
    end
  end

  describe "expandable popups" do
    test "a popup without :expanded is not expandable and toggle is a no-op" do
      popup = Builder.new("collapsed", 1, 1)
      refute HoverPopup.expandable?(popup)
      assert HoverPopup.toggle_expand(popup) == popup
    end

    test "toggle_expand swaps content and flips the flag, resetting scroll" do
      popup =
        "collapsed body"
        |> Builder.new(1, 1, expanded: "the full expanded body")
        |> Map.put(:scroll_offset, 5)

      assert HoverPopup.expandable?(popup)
      refute popup.expanded?

      expanded = HoverPopup.toggle_expand(popup)
      assert expanded.expanded?
      assert expanded.scroll_offset == 0
      # content_lines now holds the expanded text; collapsed is stashed in alt.
      assert render_text(expanded.content_lines) =~ "full expanded body"
      assert render_text(expanded.alt_content_lines) =~ "collapsed body"

      back = HoverPopup.toggle_expand(expanded)
      refute back.expanded?
      assert render_text(back.content_lines) =~ "collapsed body"
    end
  end

  # Flattens parsed markdown lines back to their text for assertions.
  defp render_text(lines) do
    Enum.map_join(lines, "\n", fn {segments, _type} ->
      Enum.map_join(segments, "", fn {text, _style} -> text end)
    end)
  end

  defp tall_hover_text do
    1..40
    |> Enum.map_join("\n", &"line #{&1}")
  end
end
