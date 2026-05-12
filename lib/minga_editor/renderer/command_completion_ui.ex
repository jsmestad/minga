defmodule MingaEditor.Renderer.CommandCompletionUI do
  @moduledoc """
  Renders the ex-command completion popup above the TUI minibuffer.

  Produces `DisplayList.draw()` tuples for a cell-painted popup showing
  matching commands with label, description, keybinding annotation, and
  fuzzy match character highlighting.
  """

  alias Minga.Core.Face
  alias MingaEditor.DisplayList
  alias MingaEditor.State.ModalOverlay.CommandCompletion, as: Payload

  @max_rows 10
  @label_col_width 22

  @typedoc "Render context with minibuffer position and viewport dimensions."
  @type render_opts :: %{
          minibuffer_row: non_neg_integer(),
          top_boundary: non_neg_integer(),
          viewport_rows: non_neg_integer(),
          viewport_cols: non_neg_integer()
        }

  @spec render(Payload.t() | nil, render_opts(), map()) :: [DisplayList.draw()]
  def render(nil, _opts, _theme), do: []

  def render(%Payload{candidates: []}, _opts, _theme), do: []

  def render(%Payload{} = payload, opts, theme) do
    visible_count = min(length(payload.candidates), max_visible(opts))
    visible = Enum.take(payload.candidates, visible_count)
    start_row = opts.minibuffer_row - visible_count
    popup_width = opts.viewport_cols

    pc = theme.picker
    bg = pc.bg
    sel_bg = pc.sel_bg
    text_fg = pc.text_fg
    highlight_fg = pc.highlight_fg
    dim_fg = pc.dim_fg
    accent_fg = Map.get(theme, :accent, highlight_fg)

    visible
    |> Enum.with_index()
    |> Enum.flat_map(fn {candidate, idx} ->
      row = start_row + idx

      if row >= 0 and row < opts.viewport_rows do
        is_selected = idx == payload.selected

        render_candidate_row(row, popup_width, candidate, is_selected, %{
          bg: bg,
          sel_bg: sel_bg,
          text_fg: text_fg,
          highlight_fg: highlight_fg,
          accent_fg: accent_fg,
          dim_fg: dim_fg
        })
      else
        []
      end
    end)
  end

  @spec max_visible(render_opts()) :: pos_integer()
  defp max_visible(opts) do
    available = opts.minibuffer_row - opts.top_boundary
    min(@max_rows, max(available, 0))
  end

  @spec render_candidate_row(
          non_neg_integer(),
          pos_integer(),
          map(),
          boolean(),
          map()
        ) :: [DisplayList.draw()]
  defp render_candidate_row(row, width, candidate, is_selected, colors) do
    bg = if is_selected, do: colors.sel_bg, else: colors.bg
    text_fg = if is_selected, do: colors.highlight_fg, else: colors.text_fg

    label = candidate.label
    description = Map.get(candidate, :description, "")
    annotation = Map.get(candidate, :annotation, "")
    match_positions = MapSet.new(Map.get(candidate, :match_positions, []))

    label_col = 2
    label_width = min(String.length(label), @label_col_width)
    desc_col = label_col + @label_col_width + 1
    annotation_width = String.length(annotation)

    desc_max =
      if annotation_width > 0 do
        width - desc_col - annotation_width - 3
      else
        width - desc_col - 1
      end

    desc_text =
      if desc_max > 5 do
        String.slice(description, 0, desc_max)
      else
        ""
      end

    annotation_col = width - annotation_width - 2

    bg_draw =
      DisplayList.draw(
        row,
        0,
        String.duplicate(" ", width),
        Face.new(fg: text_fg, bg: bg)
      )

    kind_draw =
      DisplayList.draw(row, 0, " :", Face.new(fg: colors.dim_fg, bg: bg))

    label_draws =
      render_highlighted_label(
        row,
        label_col,
        label,
        label_width,
        match_positions,
        is_selected,
        bg,
        colors
      )

    desc_draws =
      if desc_text != "" do
        [DisplayList.draw(row, desc_col, desc_text, Face.new(fg: colors.dim_fg, bg: bg))]
      else
        []
      end

    annotation_draws =
      if annotation_width > 0 and annotation_col > desc_col do
        [DisplayList.draw(row, annotation_col, annotation, Face.new(fg: colors.dim_fg, bg: bg))]
      else
        []
      end

    [bg_draw, kind_draw] ++ label_draws ++ desc_draws ++ annotation_draws
  end

  @spec render_highlighted_label(
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          pos_integer(),
          MapSet.t(),
          boolean(),
          non_neg_integer(),
          map()
        ) :: [DisplayList.draw()]
  defp render_highlighted_label(
         row,
         col,
         label,
         max_width,
         match_positions,
         is_selected,
         bg,
         colors
       ) do
    label
    |> String.graphemes()
    |> Enum.take(max_width)
    |> Enum.with_index()
    |> Enum.map(fn {char, char_idx} ->
      is_match = MapSet.member?(match_positions, char_idx)
      fg = char_fg(is_match, is_selected, colors)

      DisplayList.draw(
        row,
        col + char_idx,
        char,
        Face.new(fg: fg, bg: bg, bold: is_match)
      )
    end)
  end

  @spec char_fg(boolean(), boolean(), map()) :: non_neg_integer()
  defp char_fg(_is_match, true, colors), do: colors.highlight_fg
  defp char_fg(true, false, colors), do: colors.accent_fg
  defp char_fg(false, false, colors), do: colors.text_fg
end
