defmodule Minga.Agent.MarkdownHighlightTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.MarkdownHighlight
  alias Minga.UI.Face
  alias Minga.UI.Highlight

  defp make_highlight(attrs) do
    theme = Keyword.get(attrs, :theme, %{})

    %Highlight{
      version: Keyword.get(attrs, :version, 1),
      spans: Keyword.get(attrs, :spans, {}),
      capture_names: attrs |> Keyword.get(:capture_names, []) |> List.to_tuple(),
      theme: theme,
      face_registry: Face.Registry.from_syntax(theme)
    }
  end

  @theme_syntax %{
    "keyword" => [fg: 0x51AFEF],
    "string" => [fg: 0x98BE65],
    "comment" => [fg: 0x5B6268],
    "variable" => [fg: 0xBBC2CF],
    "function" => [fg: 0xC678DD]
  }

  describe "stylize/4 with no highlight data (fallback path)" do
    test "plain text produces single run per line with default fg" do
      text = "Hello world"
      result = MarkdownHighlight.stylize(text, nil, @theme_syntax)

      assert length(result) == 1
      [{run_text, fg, bg, flags}] = hd(result)
      assert run_text == "Hello world"
      assert fg == 0xBBC2CF
      assert bg == 0
      assert flags == 0
    end

    test "bold text produces run with bold flag and strips markers" do
      text = "**bold text**"
      result = MarkdownHighlight.stylize(text, nil, @theme_syntax)

      assert length(result) == 1
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

      assert length(result) == 1
      [{header_text, fg, _bg, flags}] = hd(result)
      # Regex parser strips the # marker
      assert header_text == "My Header"
      assert fg == 0x51AFEF
      assert Bitwise.band(flags, 0x01) != 0
    end

    test "inline code strips backtick markers and applies code styling" do
      text = "use `GenServer` here"
      result = MarkdownHighlight.stylize(text, nil, @theme_syntax)

      assert length(result) == 1
      line = hd(result)
      code_run = Enum.find(line, fn {t, _fg, _bg, _flags} -> t == "GenServer" end)
      assert code_run != nil
      {_, fg, bg, _} = code_run
      assert fg == 0x98BE65
      assert bg == 0x21242B
    end

    test "multiline text produces multiple lines" do
      text = "line one\nline two\nline three"
      result = MarkdownHighlight.stylize(text, nil, @theme_syntax)

      assert length(result) == 3
    end

    test "fenced code block lines have code styling" do
      text = "```elixir\ndef hello, do: :world\n```"
      result = MarkdownHighlight.stylize(text, nil, @theme_syntax)

      # Three lines: header, code content, footer
      assert length(result) == 3
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
          spans: {%{start_byte: 10, end_byte: 13, capture_id: 0}},
          capture_names: ["keyword"],
          theme: %{"keyword" => [fg: 0xFF0000, bold: true]}
        )

      result = MarkdownHighlight.stylize(text, highlight, @theme_syntax, 0)

      # Line 0: code header from regex parser
      # Line 1: code content - should have tree-sitter overlay
      # Line 2: code footer from regex parser
      assert length(result) == 3

      code_line = Enum.at(result, 1)
      # The tree-sitter overlay must produce "def" with keyword coloring
      keyword_run = Enum.find(code_line, fn {t, _, _, _} -> t == "def" end)
      assert keyword_run != nil, "expected tree-sitter to produce a 'def' run"

      {_, fg, _, flags} = keyword_run
      assert fg == 0xFF0000
      assert Bitwise.band(flags, 0x01) != 0
    end

    test "code block content at nonzero byte offset uses correct spans" do
      # Simulate a message that starts at byte 100 in the full buffer
      # (e.g., there's a user message before it)
      text = "```elixir\ndef hello\n```"

      # "def hello" is 10 bytes into this message's text.
      # With buffer_byte_offset=100, the "def" keyword is at bytes 110-113.
      highlight =
        make_highlight(
          spans: {%{start_byte: 110, end_byte: 113, capture_id: 0}},
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

      highlight = make_highlight(spans: {}, capture_names: [], theme: %{})

      result = MarkdownHighlight.stylize(text, highlight, @theme_syntax, 0)

      assert length(result) == 1
      [{header_text, fg, _bg, flags}] = hd(result)
      # Still uses regex parser - strips # and applies header style
      assert header_text == "My Header"
      assert fg == 0x51AFEF
      assert Bitwise.band(flags, 0x01) != 0
    end

    test "falls back when highlight has no spans" do
      text = "**bold**"

      highlight = make_highlight(version: 0, spans: {}, capture_names: [], theme: %{})

      result = MarkdownHighlight.stylize(text, highlight, @theme_syntax)

      assert length(result) == 1
      line = hd(result)
      bold_run = Enum.find(line, fn {t, _fg, _bg, _flags} -> t == "bold" end)
      assert bold_run != nil
    end
  end
end
