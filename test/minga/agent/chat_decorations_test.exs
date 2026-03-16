defmodule Minga.Agent.ChatDecorationsTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.ChatDecorations
  alias Minga.Buffer.Decorations

  defp test_theme do
    Minga.Theme.agent_theme(Minga.Theme.get!(Minga.Theme.default()))
  end

  describe "build_decorations/3" do
    test "user message gets header block decoration" do
      decs = Decorations.new()
      messages = [{:user, "hello world"}]
      offsets = [{0, 0, 3}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      assert Decorations.has_block_decorations?(result)
    end

    test "assistant message gets header block decoration" do
      decs = Decorations.new()
      messages = [{:assistant, "I can help with that."}]
      offsets = [{0, 0, 3}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      assert Decorations.has_block_decorations?(result)
    end

    test "collapsed thinking gets fold region" do
      decs = Decorations.new()
      messages = [{:thinking, "analyzing the code...", true}]
      offsets = [{0, 0, 5}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      assert Decorations.has_fold_regions?(result)
      fold = hd(Decorations.closed_fold_regions(result))
      assert fold.start_line == 0
      assert fold.end_line == 4
    end

    test "open thinking gets no fold region" do
      decs = Decorations.new()
      messages = [{:thinking, "analyzing...", false}]
      offsets = [{0, 0, 3}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      refute Decorations.has_fold_regions?(result)
    end

    test "tool call gets header block and output fold" do
      tc = %{
        name: "read_file",
        status: :complete,
        result: "file content here\nline 2\nline 3",
        collapsed: false
      }

      decs = Decorations.new()
      messages = [{:tool_call, tc}]
      offsets = [{0, 0, 6}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      assert Decorations.has_block_decorations?(result)
      # Tool output fold region (open by default, collapsible with za)
      assert Decorations.has_fold_regions?(result)
    end

    test "running tool call has no fold (still streaming)" do
      tc = %{name: "shell", status: :running, result: "", collapsed: false}
      decs = Decorations.new()
      messages = [{:tool_call, tc}]
      offsets = [{0, 0, 1}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      refute Decorations.has_fold_regions?(result)
    end

    test "multiple messages get independent decorations" do
      decs = Decorations.new()

      messages = [
        {:user, "hi"},
        {:assistant, "hello"},
        {:user, "thanks"}
      ]

      offsets = [{0, 0, 3}, {1, 5, 3}, {2, 10, 3}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      {above, _below} = Decorations.blocks_for_line(result, 0)
      assert length(above) == 1

      {above2, _} = Decorations.blocks_for_line(result, 5)
      assert length(above2) == 1

      {above3, _} = Decorations.blocks_for_line(result, 10)
      assert length(above3) == 1
    end

    test "usage messages get a dim highlight" do
      decs = Decorations.new()
      messages = [{:usage, %{input: 100, output: 50, cost: 0.001}}]
      offsets = [{0, 0, 1}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      # Usage gets a highlight decoration for dim styling, but no block decorations
      {above, below} = Decorations.blocks_for_line(result, 0)
      assert above == []
      assert below == []
      refute Decorations.empty?(result)
    end
  end

  describe "markdown delimiter dimming" do
    test "assistant message bold delimiters are dimmed" do
      decs = Decorations.new()
      messages = [{:assistant, "This is **bold** text"}]
      offsets = [{0, 0, 1}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      # Should have highlight decorations for the ** delimiters
      highlights = Decorations.highlights_for_line(result, 0)
      # Find highlights in the :chat_md_delimiters group
      delimiter_highlights = Enum.filter(highlights, fn hl -> hl.group == :chat_md_delimiters end)

      assert [_, _ | _] = delimiter_highlights,
             "Expected at least 2 delimiter highlights for **bold**"
    end

    test "heading markers are dimmed" do
      decs = Decorations.new()
      messages = [{:assistant, "# Heading"}]
      offsets = [{0, 0, 1}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      highlights = Decorations.highlights_for_line(result, 0)
      delimiter_highlights = Enum.filter(highlights, fn hl -> hl.group == :chat_md_delimiters end)
      assert [_ | _] = delimiter_highlights, "Expected heading marker to be dimmed"
    end

    test "inline code backticks are dimmed" do
      decs = Decorations.new()
      messages = [{:assistant, "Use `code` here"}]
      offsets = [{0, 0, 1}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      highlights = Decorations.highlights_for_line(result, 0)
      delimiter_highlights = Enum.filter(highlights, fn hl -> hl.group == :chat_md_delimiters end)
      assert [_, _ | _] = delimiter_highlights, "Expected backtick delimiters to be dimmed"
    end

    test "fenced code block markers are dimmed" do
      decs = Decorations.new()
      messages = [{:assistant, "```elixir\nIO.puts(\"hi\")\n```"}]
      offsets = [{0, 0, 3}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      # Both ``` lines should have delimiter highlights
      fence_open = Decorations.highlights_for_line(result, 0)
      fence_close = Decorations.highlights_for_line(result, 2)

      open_delims = Enum.filter(fence_open, fn hl -> hl.group == :chat_md_delimiters end)
      close_delims = Enum.filter(fence_close, fn hl -> hl.group == :chat_md_delimiters end)

      assert [_ | _] = open_delims, "Expected opening fence to be dimmed"
      assert [_ | _] = close_delims, "Expected closing fence to be dimmed"
    end

    test "content inside code blocks is not dimmed" do
      decs = Decorations.new()
      messages = [{:assistant, "```\n**not bold**\n```"}]
      offsets = [{0, 0, 3}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      # Line 1 (inside code block) should NOT have delimiter dimming for **
      inner_highlights = Decorations.highlights_for_line(result, 1)
      inner_delims = Enum.filter(inner_highlights, fn hl -> hl.group == :chat_md_delimiters end)
      assert inner_delims == [], "Content inside code blocks should not have delimiter dimming"
    end

    test "link delimiters are dimmed" do
      decs = Decorations.new()
      messages = [{:assistant, "See [link](https://example.com) here"}]
      offsets = [{0, 0, 1}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      highlights = Decorations.highlights_for_line(result, 0)
      delimiter_highlights = Enum.filter(highlights, fn hl -> hl.group == :chat_md_delimiters end)
      # Should dim: [, ](, the URL, and )
      assert [_, _, _ | _] = delimiter_highlights, "Expected link delimiters to be dimmed"
    end

    test "list markers are dimmed" do
      decs = Decorations.new()
      messages = [{:assistant, "- item one\n1. item two"}]
      offsets = [{0, 0, 2}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      line0_highlights = Decorations.highlights_for_line(result, 0)
      line0_delims = Enum.filter(line0_highlights, fn hl -> hl.group == :chat_md_delimiters end)
      assert [_ | _] = line0_delims, "Expected unordered list marker to be dimmed"

      line1_highlights = Decorations.highlights_for_line(result, 1)
      line1_delims = Enum.filter(line1_highlights, fn hl -> hl.group == :chat_md_delimiters end)
      assert [_ | _] = line1_delims, "Expected ordered list marker to be dimmed"
    end

    test "multibyte characters before delimiters use correct grapheme columns" do
      decs = Decorations.new()
      # "café **bold**" - the é is 2 bytes but 1 grapheme
      messages = [{:assistant, "café **bold**"}]
      offsets = [{0, 0, 1}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      highlights = Decorations.highlights_for_line(result, 0)
      delimiter_highlights = Enum.filter(highlights, fn hl -> hl.group == :chat_md_delimiters end)

      # The ** delimiters should be at grapheme columns 5-7 and 11-13, not byte columns
      # Verify they exist and cover the right positions
      assert Enum.any?(delimiter_highlights, fn hl ->
               # Opening ** starts at grapheme column 5 (c=0, a=1, f=2, é=3, space=4, **=5)
               hl.start == {0, 5} and hl.end_ == {0, 7}
             end),
             "Expected opening ** at grapheme column 5, got: #{inspect(Enum.map(delimiter_highlights, fn hl -> {hl.start, hl.end_} end))}"
    end

    test "user messages don't get markdown delimiter dimming" do
      decs = Decorations.new()
      messages = [{:user, "This is **bold** text"}]
      offsets = [{0, 0, 1}]

      result = ChatDecorations.build_decorations(decs, messages, offsets, test_theme())

      highlights = Decorations.highlights_for_line(result, 0)
      delimiter_highlights = Enum.filter(highlights, fn hl -> hl.group == :chat_md_delimiters end)

      assert delimiter_highlights == [],
             "User messages should not have markdown delimiter dimming"
    end
  end
end
