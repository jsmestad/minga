defmodule MingaEditor.HoverPopup.Builder do
  @moduledoc "Builds hover lifecycle values from markdown, including bounded syntax-highlighting service work."

  alias MingaAgent.Markdown
  alias MingaEditor.HoverPopup
  alias MingaEditor.HoverPopup.SyntaxHighlight
  alias MingaEditor.UI.Theme

  @doc "Builds cursor-anchored hover content from markdown."
  @spec new(String.t(), non_neg_integer(), non_neg_integer(), keyword()) :: HoverPopup.t()
  def new(markdown_text, cursor_row, cursor_col, opts \\ []) do
    theme = Keyword.get(opts, :theme, Theme.get!(Theme.default()))

    parse = fn markdown ->
      markdown |> Markdown.parse() |> SyntaxHighlight.enhance(theme, opts)
    end

    alternate =
      case Keyword.get(opts, :expanded) do
        nil -> nil
        expanded_markdown -> parse.(expanded_markdown)
      end

    HoverPopup.from_parsed_lines(parse.(markdown_text), cursor_row, cursor_col, alternate)
  end

  @doc "Builds the ordered code hover and its compact preview."
  @spec code_document(HoverPopup.code_sections(), String.t(), Theme.t()) ::
          {[Markdown.parsed_line()], [Markdown.parsed_line()]}
  def code_document({diagnostics, attribution}, markdown, theme) do
    docs = markdown |> Markdown.parse() |> SyntaxHighlight.enhance(theme, [])

    {add_code_sections(diagnostics, docs, attribution),
     add_code_sections(diagnostics, preview(docs), attribution)}
  end

  @doc "Builds a local hover without documentation."
  @spec local_code(HoverPopup.code_sections()) :: [Markdown.parsed_line()]
  def local_code({diagnostics, attribution}), do: join_sections(diagnostics, attribution)

  @spec add_code_sections([Markdown.parsed_line()], [Markdown.parsed_line()], [
          Markdown.parsed_line()
        ]) ::
          [Markdown.parsed_line()]
  defp add_code_sections(diagnostics, docs, attribution),
    do: join_sections(diagnostics, join_sections(docs, attribution))

  @spec preview([Markdown.parsed_line()]) :: [Markdown.parsed_line()]
  defp preview([{_segments, {:code_header, _language}} = first | rest]) do
    {code, docs} = Enum.split_while(rest, fn {_segments, type} -> type == :code end)
    join_sections([first | code], first_paragraph(docs))
  end

  defp preview(docs), do: first_paragraph(docs)

  @spec first_paragraph([Markdown.parsed_line()]) :: [Markdown.parsed_line()]
  defp first_paragraph(lines) do
    lines
    |> Enum.drop_while(fn {_segments, type} -> type == :empty end)
    |> Enum.take_while(fn {_segments, type} -> type != :empty end)
  end

  @spec join_sections([Markdown.parsed_line()], [Markdown.parsed_line()]) ::
          [Markdown.parsed_line()]
  defp join_sections([], right), do: right
  defp join_sections(left, []), do: left
  defp join_sections(left, right), do: Enum.concat(left, [{[], :empty} | right])
end
