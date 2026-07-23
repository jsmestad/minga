defmodule MingaEditor.Agent.MarkdownHighlightTest do
  use ExUnit.Case, async: true

  alias Minga.Language.Highlight.Span
  alias MingaEditor.Agent.MarkdownHighlight

  alias MingaEditor.UI.Highlight

  defp make_highlight(attrs) do
    theme = Keyword.get(attrs, :theme, %{})

    Highlight.new(theme)
    |> Highlight.put_names(Keyword.get(attrs, :capture_names, []))
    |> Highlight.put_spans(Keyword.get(attrs, :version, 1), Keyword.get(attrs, :spans, []))
  end

  @theme_syntax %{
    "keyword" => [fg: 0x51AFEF],
    "string" => [fg: 0x98BE65],
    "comment" => [fg: 0x5B6268],
    "variable" => [fg: 0xBBC2CF],
    "function" => [fg: 0xC678DD],
    "markup.link.label" => [fg: 0x61AFEF]
  }

  describe "stylize/4 with no highlight data (fallback path)" do
    test "plain text produces single run per line with default fg" do
      text = "Hello world"
      result = MarkdownHighlight.stylize(text, nil, @theme_syntax)

      assert Enum.count(result) == 1
      [{run_text, fg, bg, flags}] = hd(result)
      assert run_text == "Hello world"
      assert fg == 0xBBC2CF
      assert bg == 0
      assert flags == 0
    end

    test "bold text produces run with bold flag and strips markers" do
      text = "**bold text**"
      result = MarkdownHighlight.stylize(text, nil, @theme_syntax)

      assert Enum.count(result) == 1
      line = hd(result)

      bold_run =
        Enum.find(line, fn {_text, _fg, _bg, flags} -> Bitwise.band(flags, 0x01) != 0 end)

      assert bold_run != nil
      {text, _fg, _bg, _flags} = bold_run
      # Regex parser strips the ** markers
      assert text == "bold text"
    end

    test "header strips # markers and applies bold + keyword color" do
      text = "# My Header"
      result = MarkdownHighlight.stylize(text, nil, @theme_syntax)

      assert Enum.count(result) == 1
      [{header_text, fg, _bg, flags}] = hd(result)
      # Regex parser strips the # marker
      assert header_text == "My Header"
      assert fg == 0x51AFEF
      assert Bitwise.band(flags, 0x01) != 0
    end

    test "inline code strips backtick markers and applies code styling" do
      text = "use `GenServer` here"
      result = MarkdownHighlight.stylize(text, nil, @theme_syntax)

      assert Enum.count(result) == 1
      line = hd(result)
      code_run = Enum.find(line, fn {t, _fg, _bg, _flags} -> t == "GenServer" end)
      assert code_run != nil
      {_, fg, bg, flags} = code_run
      assert fg == 0x98BE65
      assert bg == 0x21242B
      assert Bitwise.band(flags, 0x10) != 0
    end

    test "link text strips markdown and carries url metadata" do
      text = "Read [the docs](https://example.com/docs)"
      result = MarkdownHighlight.stylize(text, nil, @theme_syntax)

      line = hd(result)

      link_run =
        Enum.find(line, fn
          {"the docs", _fg, _bg, _flags, _url} -> true
          _ -> false
        end)

      assert {"the docs", 0x61AFEF, 0, flags, "https://example.com/docs"} = link_run
      assert Bitwise.band(flags, 0x04) != 0
      assert Bitwise.band(flags, 0x08) != 0
    end

    test "multiline text produces multiple lines" do
      text = "line one\nline two\nline three"
      result = MarkdownHighlight.stylize(text, nil, @theme_syntax)

      assert Enum.count(result) == 3
    end

    test "fenced code block lines have code styling" do
      text = "```elixir\ndef hello, do: :world\n```"
      result = MarkdownHighlight.stylize(text, nil, @theme_syntax)

      # Three lines: header, code content, footer
      assert Enum.count(result) == 3
      [{_text, _fg, _bg, flags}] = Enum.at(result, 1)
      assert Bitwise.band(flags, 0x10) != 0
    end
  end

  describe "stylize/4 with tree-sitter highlights and byte offsets" do
    test "code block content at byte offset 0 gets tree-sitter styling" do
      # Simulate a simple code block as the entire message
      text = "```elixir\ndef hello\n```"

      # Tree-sitter would highlight "def" in the code line.
      # The code line "def hello" starts at byte 10 (after "```elixir\n")
      highlight =
        make_highlight(
          spans: [Span.new(10, 13, 0)],
          capture_names: ["keyword"],
          theme: %{"keyword" => [fg: 0xFF0000, bold: true]}
        )

      result = MarkdownHighlight.stylize(text, highlight, @theme_syntax, 0)

      # Line 0: code header from regex parser
      # Line 1: code content - should have tree-sitter overlay
      # Line 2: code footer from regex parser
      assert Enum.count(result) == 3

      code_line = Enum.at(result, 1)
      # The tree-sitter overlay must produce "def" with keyword coloring
      keyword_run = Enum.find(code_line, fn {t, _, _, _} -> t == "def" end)
      assert keyword_run != nil, "expected tree-sitter to produce a 'def' run"

      {_, fg, bg, flags} = keyword_run
      assert fg == 0xFF0000
      assert bg != 0
      assert Bitwise.band(flags, 0x01) != 0
      assert Bitwise.band(flags, 0x10) != 0
    end

    test "code block content at nonzero byte offset uses correct spans" do
      # Simulate a message that starts at byte 100 in the full buffer
      # (e.g., there's a user message before it)
      text = "```elixir\ndef hello\n```"

      # "def hello" is 10 bytes into this message's text.
      # With buffer_byte_offset=100, the "def" keyword is at bytes 110-113.
      highlight =
        make_highlight(
          spans: [Span.new(110, 113, 0)],
          capture_names: ["keyword"],
          theme: %{"keyword" => [fg: 0xFF0000, bold: true]}
        )

      result = MarkdownHighlight.stylize(text, highlight, @theme_syntax, 100)

      code_line = Enum.at(result, 1)
      keyword_run = Enum.find(code_line, fn {t, _, _, _} -> t == "def" end)
      assert keyword_run != nil, "expected tree-sitter to produce a 'def' run at offset 100"

      {_, fg, _, _flags} = keyword_run
      assert fg == 0xFF0000
    end

    test "non-code lines keep regex parser styling even with highlights" do
      # A header line should NOT be overridden by tree-sitter
      text = "# My Header"

      highlight = make_highlight(spans: [], capture_names: [], theme: %{})

      result = MarkdownHighlight.stylize(text, highlight, @theme_syntax, 0)

      assert Enum.count(result) == 1
      [{header_text, fg, _bg, flags}] = hd(result)
      # Still uses regex parser - strips # and applies header style
      assert header_text == "My Header"
      assert fg == 0x51AFEF
      assert Bitwise.band(flags, 0x01) != 0
    end

    test "open fenced block skips tree-sitter overlay while preserving code flag" do
      text = "```elixir\ndef hello"

      highlight =
        make_highlight(
          spans: [Span.new(10, 13, 0)],
          capture_names: ["keyword"],
          theme: %{"keyword" => [fg: 0xFF0000, bold: true]}
        )

      result = MarkdownHighlight.stylize(text, highlight, @theme_syntax, 0)

      [{code_text, fg, _bg, flags}] = Enum.at(result, 1)
      assert code_text == "def hello"
      assert fg == 0x98BE65
      assert Bitwise.band(flags, 0x10) != 0
      refute Bitwise.band(flags, 0x01) != 0
    end

    test "falls back when highlight has no spans" do
      text = "**bold**"

      highlight = make_highlight(version: 0, spans: [], capture_names: [], theme: %{})

      result = MarkdownHighlight.stylize(text, highlight, @theme_syntax)

      assert Enum.count(result) == 1
      line = hd(result)
      bold_run = Enum.find(line, fn {t, _fg, _bg, _flags} -> t == "bold" end)
      assert bold_run != nil
    end
  end

  describe "render_blocks/5" do
    test "inline code remains a run flag inside a paragraph block" do
      [block] = MarkdownHighlight.render_blocks("Use `GenServer` here", nil, @theme_syntax, 42)

      assert block.kind == :paragraph
      assert [[{"Use ", _, 0, 0}, {"GenServer", _, _, flags}, {" here", _, 0, 0}]] = block.lines
      assert Bitwise.band(flags, 0x10) != 0
    end

    test "fenced code becomes an explicit complete code block" do
      [_paragraph, code] =
        MarkdownHighlight.render_blocks(
          "In `lib/demo.ex`:\n```elixir\ndef hello\n```",
          nil,
          @theme_syntax,
          42
        )

      assert code.kind == :code_block
      assert code.language == "elixir"
      assert code.label == "Elixir"
      assert code.target_path == "lib/demo.ex"
      assert code.flags == 0x01
      assert [[{"def hello", _, _, flags}]] = code.lines
      assert Bitwise.band(flags, 0x10) != 0
    end

    test "unclosed fenced code block is semantic streaming code" do
      [code] = MarkdownHighlight.render_blocks("```python\nprint('hi')", nil, @theme_syntax, 99)

      assert code.kind == :code_block
      assert code.language == "python"
      assert code.label == "Python"
      assert code.flags == 0
      assert [[{"print('hi')", _, _, flags}]] = code.lines
      assert Bitwise.band(flags, 0x10) != 0
    end

    test "complete fenced code block keeps tree-sitter styling in semantic code card" do
      text = "```elixir\ndef hello\n```"

      highlight =
        make_highlight(
          spans: [Span.new(10, 13, 0)],
          capture_names: ["keyword"],
          theme: %{"keyword" => [fg: 0xFF0000, bold: true]}
        )

      [code] = MarkdownHighlight.render_blocks(text, highlight, @theme_syntax, 99)

      keyword_run =
        code.lines |> hd() |> Enum.find(fn {text, _fg, _bg, _flags} -> text == "def" end)

      assert {"def", 0xFF0000, _, flags} = keyword_run
      assert Bitwise.band(flags, 0x01) != 0
      assert Bitwise.band(flags, 0x10) != 0
    end

    test "complete semantic code card requests snippet highlighting when no full-message highlight exists" do
      test_pid = self()
      text = "```elixir\ndef hello\n```"

      highlighter = fn language, source, opts ->
        send(test_pid, {:highlight_requested, language, source, opts})
        {:ok, ["keyword"], [Span.new(0, 3, 0)]}
      end

      [code] =
        MarkdownHighlight.render_blocks(text, nil, @theme_syntax, 99, 0, highlighter: highlighter)

      assert_received {:highlight_requested, "elixir", "def hello", opts}
      assert opts[:timeout]

      keyword_run =
        code.lines |> hd() |> Enum.find(fn {text, _fg, _bg, _flags} -> text == "def" end)

      assert {"def", 0x51AFEF, _, flags} = keyword_run
      assert Bitwise.band(flags, 0x10) != 0
    end

    test "indented code becomes a complete semantic code card" do
      [code] =
        MarkdownHighlight.render_blocks("    def hello\n    :world", nil, @theme_syntax, 99)

      assert code.kind == :code_block
      assert code.language == ""
      assert code.label == "Code"
      assert code.flags == 0x01
      assert [[{"def hello", _, _, flags}], [{":world", _, _, _}]] = code.lines
      assert Bitwise.band(flags, 0x10) != 0
    end

    test "indented code preserves blank lines in the semantic code card" do
      [code] = MarkdownHighlight.render_blocks("    one\n\n    two", nil, @theme_syntax, 99)

      assert code.kind == :code_block
      assert code.language == ""
      assert code.label == "Code"
      assert code.flags == 0x01
      assert [[{"one", _, _, flags}], [{"", _, _, _}], [{"two", _, _, _}]] = code.lines
      assert Bitwise.band(flags, 0x10) != 0
    end

    test "incomplete semantic code card stays plain monospaced while streaming" do
      text = "```elixir\ndef hello"

      highlight =
        make_highlight(
          spans: [Span.new(10, 13, 0)],
          capture_names: ["keyword"],
          theme: %{"keyword" => [fg: 0xFF0000, bold: true]}
        )

      [code] = MarkdownHighlight.render_blocks(text, highlight, @theme_syntax, 99)

      assert code.flags == 0
      assert [[{"def hello", 0x98BE65, _, flags}]] = code.lines
      assert Bitwise.band(flags, 0x10) != 0
      refute Bitwise.band(flags, 0x01) != 0
    end

    test "incomplete semantic code card does not request completed-block highlighting" do
      test_pid = self()

      highlighter = fn language, source, opts ->
        send(test_pid, {:unexpected_highlight, language, source, opts})
        {:ok, ["keyword"], [Span.new(0, 3, 0)]}
      end

      [code] =
        MarkdownHighlight.render_blocks("```elixir\ndef hello", nil, @theme_syntax, 99, 0,
          highlighter: highlighter
        )

      assert code.kind == :code_block
      assert code.flags == 0
      refute_received {:unexpected_highlight, _language, _source, _opts}
    end
  end
end
