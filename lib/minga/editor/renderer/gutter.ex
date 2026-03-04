defmodule Minga.Editor.Renderer.Gutter do
  @moduledoc """
  Line number gutter and diagnostic sign column rendering.

  The gutter has two parts (left to right):
  1. **Sign column** (2 chars) — diagnostic severity icons (`E `, `W `, etc.)
  2. **Line numbers** (variable width) — absolute, relative, or hybrid

  The sign column is always present when diagnostics exist for the buffer.
  """

  alias Minga.Diagnostics.Diagnostic
  alias Minga.Port.Protocol

  @sign_col_width 2

  @typedoc "Line number display style."
  @type line_number_style :: :hybrid | :absolute | :relative | :none

  @typedoc "Gutter color set from the active theme."
  @type colors :: Minga.Theme.Gutter.t()

  @doc """
  Returns the total gutter width including sign column and line numbers.

  The sign column adds 2 characters when diagnostics are present.
  """
  @spec total_width(non_neg_integer(), boolean()) :: non_neg_integer()
  def total_width(line_number_w, has_diagnostics) do
    sign_w = if has_diagnostics, do: @sign_col_width, else: 0
    sign_w + line_number_w
  end

  @doc "Returns the width of the sign column."
  @spec sign_column_width() :: non_neg_integer()
  def sign_column_width, do: @sign_col_width

  @doc "Renders the sign column for a line. Returns a draw command or empty list."
  @spec render_sign(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          %{non_neg_integer() => Diagnostic.severity()},
          colors()
        ) :: binary() | []
  def render_sign(_screen_row, _col_offset, _buf_line, signs, _colors)
      when map_size(signs) == 0,
      do: []

  def render_sign(screen_row, col_offset, buf_line, signs, colors) do
    case Map.get(signs, buf_line) do
      nil ->
        Protocol.encode_draw(screen_row, col_offset, "  ")

      severity ->
        {icon, fg} = sign_for_severity(severity, colors)
        Protocol.encode_draw(screen_row, col_offset, icon, fg: fg)
    end
  end

  @doc "Renders a single gutter number at `screen_row`."
  @spec render_number(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          line_number_style(),
          colors()
        ) :: binary() | []
  def render_number(_screen_row, _col_offset, _buf_line, _cursor_line, 0, :none, _colors),
    do: []

  def render_number(screen_row, col_offset, buf_line, cursor_line, line_number_w, style, colors) do
    {number, fg} = number_and_color(buf_line, cursor_line, style, colors)

    num_str = Integer.to_string(number)
    padded = String.pad_leading(num_str, line_number_w - 1)
    Protocol.encode_draw(screen_row, col_offset, padded, fg: fg)
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec sign_for_severity(Diagnostic.severity(), colors()) :: {String.t(), non_neg_integer()}
  defp sign_for_severity(:error, colors), do: {"E ", colors.error_fg}
  defp sign_for_severity(:warning, colors), do: {"W ", colors.warning_fg}
  defp sign_for_severity(:info, colors), do: {"I ", colors.info_fg}
  defp sign_for_severity(:hint, colors), do: {"H ", colors.hint_fg}

  @spec number_and_color(non_neg_integer(), non_neg_integer(), line_number_style(), colors()) ::
          {non_neg_integer(), non_neg_integer()}
  defp number_and_color(buf_line, _cursor_line, :absolute, colors) do
    {buf_line + 1, colors.current_fg}
  end

  defp number_and_color(buf_line, cursor_line, :relative, colors) do
    {abs(buf_line - cursor_line), colors.fg}
  end

  defp number_and_color(buf_line, cursor_line, :hybrid, colors) do
    if buf_line == cursor_line do
      {buf_line + 1, colors.current_fg}
    else
      {abs(buf_line - cursor_line), colors.fg}
    end
  end
end
