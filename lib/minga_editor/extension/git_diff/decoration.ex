defmodule MingaEditor.Extension.GitDiff.Decoration do
  @moduledoc false

  alias Minga.Core.Color
  alias Minga.Core.Decorations
  alias Minga.Core.Diff
  alias Minga.Core.DiffView
  alias Minga.Core.Face
  alias MingaEditor.UI.Theme

  @typep change_style :: {Face.t(), Face.t()}
  @typep styles :: %{added: change_style(), removed: change_style(), fold: Face.t()}

  @spec apply(Decorations.t(), [DiffView.line_meta()], Theme.t()) :: Decorations.t()
  def apply(decorations, lines, theme) do
    styles = %{
      added: change_style(theme.editor.bg, theme.git.added_fg),
      removed: change_style(theme.editor.bg, theme.git.deleted_fg),
      fold: Face.new(fg: theme.gutter.fg, italic: true)
    }

    lines
    |> Stream.with_index()
    |> Enum.reduce(decorations, fn {meta, row}, acc -> decorate(acc, meta, row, styles) end)
  end

  @spec decorate(Decorations.t(), DiffView.line_meta(), non_neg_integer(), styles()) ::
          Decorations.t()
  defp decorate(
         decs,
         %{left_type: left, right_type: right, left_width: width} = meta,
         row,
         styles
       ) do
    decs
    |> pane(left, row, 0, width, styles, meta[:left_word_changes])
    |> pane(right, row, width + 3, 9999, styles, meta[:right_word_changes])
  end

  defp decorate(decs, %{type: type, word_changes: words}, row, styles),
    do: pane(decs, type, row, 0, 9999, styles, words)

  @spec pane(
          Decorations.t(),
          DiffView.line_type() | DiffView.pane_line_type(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          styles(),
          [Diff.char_range()] | nil
        ) :: Decorations.t()
  defp pane(decs, type, row, first, last, styles, words) when type in [:added, :removed] do
    {face, word_face} = Map.fetch!(styles, type)
    decs = highlight(decs, :diff, row, first, last, face, 1)

    Enum.reduce(words || [], decs, fn {from, to}, acc ->
      highlight(acc, :diff_word, row, first + from, first + to, word_face, 2)
    end)
  end

  defp pane(decs, :fold, row, first, last, styles, _words),
    do: highlight(decs, :diff, row, first, last, styles.fold, 1)

  defp pane(decs, _type, _row, _first, _last, _styles, _words), do: decs

  @spec highlight(
          Decorations.t(),
          atom(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          Face.t(),
          pos_integer()
        ) :: Decorations.t()
  defp highlight(decs, group, row, first, last, face, priority) do
    Decorations.highlight_group(decs, group, {row, first}, {row, last},
      style: face,
      priority: priority
    )
  end

  @spec change_style(non_neg_integer(), non_neg_integer()) :: change_style()
  defp change_style(background, foreground) do
    {Face.new(bg: Color.interpolate(background, foreground, 0.15)),
     Face.new(bg: Color.interpolate(background, foreground, 0.35))}
  end
end
