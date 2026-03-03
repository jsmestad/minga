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

  @gutter_fg 0x555555
  @gutter_current_fg 0xBBC2CF

  # Doom One diagnostic colors
  @error_fg 0xFF6C6B
  @warning_fg 0xECBE7B
  @info_fg 0x51AFEF
  @hint_fg 0x555555

  @sign_col_width 2

  @typedoc "Line number display style."
  @type line_number_style :: :hybrid | :absolute | :relative | :none

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
          %{non_neg_integer() => Diagnostic.severity()}
        ) :: binary() | []
  def render_sign(_screen_row, _col_offset, _buf_line, signs) when map_size(signs) == 0, do: []

  def render_sign(screen_row, col_offset, buf_line, signs) do
    case Map.get(signs, buf_line) do
      nil ->
        Protocol.encode_draw(screen_row, col_offset, "  ")

      severity ->
        {icon, fg} = sign_for_severity(severity)
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
          line_number_style()
        ) :: binary() | []
  def render_number(_screen_row, _col_offset, _buf_line, _cursor_line, 0, :none), do: []

  def render_number(screen_row, col_offset, buf_line, cursor_line, line_number_w, style) do
    {number, fg} = number_and_color(buf_line, cursor_line, style)

    num_str = Integer.to_string(number)
    padded = String.pad_leading(num_str, line_number_w - 1)
    Protocol.encode_draw(screen_row, col_offset, padded, fg: fg)
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec sign_for_severity(Diagnostic.severity()) :: {String.t(), non_neg_integer()}
  defp sign_for_severity(:error), do: {"E ", @error_fg}
  defp sign_for_severity(:warning), do: {"W ", @warning_fg}
  defp sign_for_severity(:info), do: {"I ", @info_fg}
  defp sign_for_severity(:hint), do: {"H ", @hint_fg}

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
