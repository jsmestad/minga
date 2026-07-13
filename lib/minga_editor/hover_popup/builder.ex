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
end
