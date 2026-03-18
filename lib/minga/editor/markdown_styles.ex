defmodule Minga.Editor.MarkdownStyles do
  @moduledoc """
  Maps `Minga.Agent.Markdown` style atoms to Face structs for rendering.

  Shared by all UI components that render markdown content: hover popup,
  completion doc preview, and future signature help. Centralizes the
  style-to-theme-color mapping so it doesn't drift across consumers.
  """

  alias Minga.Agent.Markdown
  alias Minga.Face

  @doc """
  Converts a markdown style atom to a Face struct.

  Uses the theme's syntax colors for code and keywords, falling back
  to `base_fg` for plain text.
  """
  @spec to_draw_opts(Markdown.style(), map(), non_neg_integer()) :: Face.t()
  def to_draw_opts(:plain, _syntax, fg), do: Face.new(fg: fg)
  def to_draw_opts(:bold, _syntax, fg), do: Face.new(fg: fg, bold: true)
  def to_draw_opts(:italic, _syntax, fg), do: Face.new(fg: fg, italic: true)
  def to_draw_opts(:bold_italic, _syntax, fg), do: Face.new(fg: fg, bold: true, italic: true)
  def to_draw_opts(:code, syntax, _fg), do: Face.new(fg: Map.get(syntax, :string, 0x98BE65))
  def to_draw_opts(:code_block, syntax, _fg), do: Face.new(fg: Map.get(syntax, :string, 0x98BE65))

  def to_draw_opts({:code_content, _lang}, syntax, _fg),
    do: Face.new(fg: Map.get(syntax, :string, 0x98BE65))

  def to_draw_opts(:header1, syntax, _fg),
    do: Face.new(fg: Map.get(syntax, :keyword, 0x51AFEF), bold: true)

  def to_draw_opts(:header2, syntax, _fg),
    do: Face.new(fg: Map.get(syntax, :keyword, 0x51AFEF), bold: true)

  def to_draw_opts(:header3, syntax, _fg),
    do: Face.new(fg: Map.get(syntax, :keyword, 0x51AFEF))

  def to_draw_opts(:blockquote, _syntax, _fg), do: Face.new(fg: 0x5B6268, italic: true)

  def to_draw_opts(:list_bullet, syntax, _fg),
    do: Face.new(fg: Map.get(syntax, :keyword, 0x51AFEF))

  def to_draw_opts(:rule, _syntax, _fg), do: Face.new(fg: 0x5B6268)
  def to_draw_opts(_other, _syntax, fg), do: Face.new(fg: fg)
end
