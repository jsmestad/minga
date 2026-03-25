defmodule Minga.Editor.Renderer.Gutter do
  @moduledoc """
  Line number gutter and diagnostic sign column rendering.

  The gutter has two parts (left to right):
  1. **Sign column** (2 chars) — always reserved for diagnostic icons, git
     signs, or annotation markers. Keeping this space constant prevents
     line numbers from shifting when signs appear or disappear.
  2. **Line numbers** (variable width) — absolute, relative, or hybrid

  All render functions return `DisplayList.draw()` tuples (or `[]`).
  """

  alias Minga.Diagnostics.Diagnostic
  alias Minga.Editor.DisplayList
  alias Minga.Face

  @sign_col_width 2

  @typedoc "Line number display style."
  @type line_number_style :: :hybrid | :absolute | :relative | :none

  @typedoc "Gutter color set from the active theme."
  @type colors :: Minga.Theme.Gutter.t()

  @doc """
  Returns the total gutter width including sign column and line numbers.

  The sign column is always reserved (2 characters) to keep the gutter
  layout consistent regardless of whether diagnostics or git markers are
  active. This prevents line numbers from shifting when signs appear.
  """
  @spec total_width(non_neg_integer()) :: non_neg_integer()
  def total_width(line_number_w) do
    @sign_col_width + line_number_w
  end

  @doc "Returns the width of the sign column."
  @spec sign_column_width() :: non_neg_integer()
  def sign_column_width, do: @sign_col_width

  @typedoc "Git sign color set from the active theme."
  @type git_colors :: Minga.Theme.Git.t()

  @doc """
  Renders the sign column for a line.

  Diagnostics take priority over git signs. If no diagnostic exists for
  the line, a git sign is shown instead. Returns a draw tuple or empty list.
  """
  @spec render_sign(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          %{non_neg_integer() => Diagnostic.severity()},
          %{non_neg_integer() => atom()},
          colors(),
          git_colors(),
          Minga.Buffer.Decorations.t()
        ) :: DisplayList.draw() | []
  def render_sign(
        screen_row,
        col_offset,
        buf_line,
        diag_signs,
        git_signs,
        colors,
        git_colors,
        decorations \\ %Minga.Buffer.Decorations{}
      ) do
    diag = Map.get(diag_signs, buf_line)
    git = Map.get(git_signs, buf_line)

    render_sign_for_line(
      screen_row,
      col_offset,
      buf_line,
      diag,
      git,
      colors,
      git_colors,
      decorations
    )
  end

  # Diagnostic sign takes highest priority.
  @spec render_sign_for_line(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          Diagnostic.severity() | nil,
          atom() | nil,
          colors(),
          git_colors(),
          Minga.Buffer.Decorations.t()
        ) :: DisplayList.draw() | []
  defp render_sign_for_line(
         screen_row,
         col_offset,
         _buf_line,
         severity,
         _git,
         colors,
         _git_colors,
         _decorations
       )
       when severity != nil do
    {icon, fg} = sign_for_severity(severity, colors)
    DisplayList.draw(screen_row, col_offset, icon, Face.new(fg: fg))
  end

  # Git sign takes second priority.
  defp render_sign_for_line(
         screen_row,
         col_offset,
         buf_line,
         nil,
         git,
         _colors,
         git_colors,
         _decorations
       )
       when git != nil do
    render_git_sign(screen_row, col_offset, buf_line, %{buf_line => git}, git_colors)
  end

  # Annotation gutter icon is the third tier; empty sign column as fallback.
  defp render_sign_for_line(
         screen_row,
         col_offset,
         buf_line,
         nil,
         nil,
         _colors,
         _git_colors,
         decorations
       ) do
    case render_annotation_sign(screen_row, col_offset, buf_line, decorations) do
      [] -> DisplayList.draw(screen_row, col_offset, "  ")
      draw -> draw
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
        ) :: DisplayList.draw() | []
  # :none means no line numbers; return nothing regardless of allocated width.
  def render_number(_screen_row, _col_offset, _buf_line, _cursor_line, _w, :none, _colors),
    do: []

  def render_number(screen_row, col_offset, buf_line, cursor_line, line_number_w, style, colors) do
    {number, fg} = number_and_color(buf_line, cursor_line, style, colors)

    num_str = Integer.to_string(number)
    padded = String.pad_leading(num_str, line_number_w - 1)
    DisplayList.draw(screen_row, col_offset, padded, Face.new(fg: fg))
  end

  # ── Private ────────────────────────────────────────────────────────────────

  # Renders the highest-priority :gutter_icon annotation in the sign column.
  # Returns [] if no gutter icon annotation exists for this line.
  @spec render_annotation_sign(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          Minga.Buffer.Decorations.t()
        ) :: DisplayList.draw() | []
  defp render_annotation_sign(_screen_row, _col_offset, _buf_line, %{annotations: []}), do: []

  defp render_annotation_sign(screen_row, col_offset, buf_line, decorations) do
    icons =
      decorations
      |> Minga.Buffer.Decorations.annotations_for_line(buf_line)
      |> Enum.filter(fn ann -> ann.kind == :gutter_icon end)

    case icons do
      [] ->
        []

      [ann | _] ->
        # Pad/truncate to sign column width (2 chars)
        text = String.pad_trailing(String.slice(ann.text, 0, @sign_col_width), @sign_col_width)
        DisplayList.draw(screen_row, col_offset, text, Face.new(fg: ann.fg))
    end
  end

  @spec render_git_sign(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          %{non_neg_integer() => atom()},
          git_colors()
        ) :: DisplayList.draw() | []
  defp render_git_sign(screen_row, col_offset, buf_line, git_signs, git_colors) do
    case Map.get(git_signs, buf_line) do
      nil ->
        DisplayList.draw(screen_row, col_offset, "  ")

      :added ->
        DisplayList.draw(screen_row, col_offset, "▎ ", Face.new(fg: git_colors.added_fg))

      :modified ->
        DisplayList.draw(screen_row, col_offset, "▎ ", Face.new(fg: git_colors.modified_fg))

      :deleted ->
        DisplayList.draw(screen_row, col_offset, "▁ ", Face.new(fg: git_colors.deleted_fg))
    end
  end

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
