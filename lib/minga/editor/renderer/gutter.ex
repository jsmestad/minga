defmodule Minga.Editor.Renderer.Gutter do
  @moduledoc """
  Line number gutter rendering: absolute, relative, and hybrid styles.
  """

  alias Minga.Port.Protocol

  @gutter_fg 0x555555
  @gutter_current_fg 0xBBC2CF

  @typedoc "Line number display style."
  @type line_number_style :: :hybrid | :absolute | :relative | :none

  @doc "Renders a single gutter number at `screen_row`."
  @spec render_number(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          line_number_style()
        ) :: binary() | []
  def render_number(_screen_row, _buf_line, _cursor_line, 0, :none), do: []

  def render_number(screen_row, buf_line, cursor_line, gutter_w, style) do
    {number, fg} = number_and_color(buf_line, cursor_line, style)

    num_str = Integer.to_string(number)
    padded = String.pad_leading(num_str, gutter_w - 1)
    Protocol.encode_draw(screen_row, 0, padded, fg: fg)
  end

  @spec number_and_color(non_neg_integer(), non_neg_integer(), line_number_style()) ::
          {non_neg_integer(), non_neg_integer()}
  defp number_and_color(buf_line, _cursor_line, :absolute) do
    {buf_line + 1, @gutter_current_fg}
  end

  defp number_and_color(buf_line, cursor_line, :relative) do
    {abs(buf_line - cursor_line), @gutter_fg}
  end

  defp number_and_color(buf_line, cursor_line, :hybrid) do
    if buf_line == cursor_line do
      {buf_line + 1, @gutter_current_fg}
    else
      {abs(buf_line - cursor_line), @gutter_fg}
    end
  end
end
