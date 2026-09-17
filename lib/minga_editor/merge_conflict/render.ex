defmodule MingaEditor.MergeConflict.Render do
  @moduledoc """
  Builds transient decorations for inline Git merge conflict resolution.

  These decorations are derived from the buffer-owned conflict index. They are composed during render and hit-testing, not stored permanently on the buffer.
  """

  alias Minga.Buffer
  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias Minga.Git.MergeConflict
  alias Minga.Git.MergeConflict.Entry

  @group :merge_conflict
  @marker_face Face.new(fg: 0x7F8490, bg: 0x2A2E3A, italic: true)
  @current_face Face.new(bg: 0x263A2E)
  @incoming_face Face.new(bg: 0x263445)
  @action_bg 0x303446
  @action_fg 0xCDD6F4
  @action_accent 0x89B4FA
  @action_bg_face Face.new(bg: @action_bg)
  @action_label_face Face.new(fg: @action_accent, bg: @action_bg, bold: true)
  @action_trailing_face Face.new(fg: @action_fg, bg: @action_bg)
  @action_specs [
    %{choice: :current, label: "Accept Current"},
    %{choice: :incoming, label: "Accept Incoming"},
    %{choice: :both, label: "Accept Both"}
  ]
  @priority 80

  @type state :: MingaEditor.State.t() | map()

  @doc "Merges merge conflict decorations into an existing decoration set."
  @spec merge_decorations(Decorations.t(), state(), pid()) :: Decorations.t()
  def merge_decorations(%Decorations{} = decorations, _state, buf) when is_pid(buf) do
    buf
    |> conflict_regions()
    |> Enum.reduce(decorations, &decorate_region/2)
  end

  def merge_decorations(%Decorations{} = decorations, _state, _buf), do: decorations

  @spec conflict_regions(pid()) :: [Entry.t()]
  defp conflict_regions(buf) do
    Buffer.conflicts(buf)
  catch
    :exit, _ -> []
  end

  @spec decorate_region(Entry.t(), Decorations.t()) :: Decorations.t()
  defp decorate_region(%Entry{} = region, decorations) do
    decorations
    |> add_marker_highlights(region)
    |> add_side_highlights(region.current_range, @current_face)
    |> add_base_highlights(region)
    |> add_side_highlights(region.incoming_range, @incoming_face)
    |> add_action_block(region)
  end

  @spec add_marker_highlights(Decorations.t(), Entry.t()) :: Decorations.t()
  defp add_marker_highlights(decorations, %Entry{} = region) do
    marker_lines = [region.start_line, region.separator_line, region.end_line]

    marker_lines =
      if region.base_marker_line, do: [region.base_marker_line | marker_lines], else: marker_lines

    Enum.reduce(marker_lines, decorations, fn line, acc ->
      add_line_highlight(acc, line, @marker_face)
    end)
  end

  @spec add_base_highlights(Decorations.t(), Entry.t()) :: Decorations.t()
  defp add_base_highlights(decorations, %Entry{base_range: nil}), do: decorations

  defp add_base_highlights(decorations, %Entry{base_range: range}) do
    add_side_highlights(decorations, range, @marker_face)
  end

  @spec add_side_highlights(Decorations.t(), Entry.line_range(), Face.t()) :: Decorations.t()
  defp add_side_highlights(decorations, {start_line, end_line}, _face) when end_line < start_line,
    do: decorations

  defp add_side_highlights(decorations, {start_line, end_line}, face) do
    {_id, decorations} =
      Decorations.add_highlight(decorations, {start_line, 0}, {end_line, 9999},
        style: face,
        priority: @priority,
        group: @group
      )

    decorations
  end

  @spec add_line_highlight(Decorations.t(), non_neg_integer(), Face.t()) :: Decorations.t()
  defp add_line_highlight(decorations, line, face),
    do: add_side_highlights(decorations, {line, line}, face)

  @spec add_action_block(Decorations.t(), Entry.t()) :: Decorations.t()
  defp add_action_block(decorations, %Entry{} = region) do
    {_id, decorations} =
      Decorations.add_block_decoration(decorations, region.start_line,
        placement: :above,
        render: &render_action_row/1,
        on_click: fn _line_idx, col -> action_for_col(col, region.start_line) end,
        priority: @priority,
        group: @group
      )

    decorations
  end

  @typep action_segment :: %{
           text: String.t(),
           face: Face.t(),
           choice: MergeConflict.choice() | nil
         }

  @spec render_action_row(pos_integer()) :: [{String.t(), Face.t()}]
  defp render_action_row(width) do
    action_segments()
    |> fit_segments(width)
  end

  @spec action_segments() :: [action_segment()]
  defp action_segments do
    label_segments =
      Enum.map(@action_specs, fn %{choice: choice, label: label} ->
        %{text: label, face: @action_label_face, choice: choice}
      end)

    [
      %{text: " ", face: @action_bg_face, choice: nil}
      | Enum.intersperse(label_segments, %{text: "  ", face: @action_bg_face, choice: nil})
    ] ++ [%{text: " ", face: @action_trailing_face, choice: nil}]
  end

  @spec fit_segments([action_segment()], pos_integer()) :: [{String.t(), Face.t()}]
  defp fit_segments(segments, width) do
    segments
    |> Enum.reduce_while({[], 0}, fn %{text: text, face: face}, {acc, used} ->
      remaining = width - used
      fit_segment(remaining, text, face, acc, used)
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @spec fit_segment(integer(), String.t(), Face.t(), [{String.t(), Face.t()}], non_neg_integer()) ::
          {:cont, {[{String.t(), Face.t()}], non_neg_integer()}}
          | {:halt, {[{String.t(), Face.t()}], non_neg_integer()}}
  defp fit_segment(remaining, _text, _face, acc, used) when remaining <= 0,
    do: {:halt, {acc, used}}

  defp fit_segment(remaining, text, face, acc, used) do
    clipped = String.slice(text, 0, remaining)
    {:cont, {[{clipped, face} | acc], used + String.length(clipped)}}
  end

  @spec action_for_col(non_neg_integer(), non_neg_integer()) ::
          {:command, {:git_accept_conflict, MergeConflict.choice(), non_neg_integer()}} | :ok
  defp action_for_col(col, start_line) do
    case Enum.find(action_ranges(), fn {range, _choice} -> col in range end) do
      nil -> :ok
      {_range, choice} -> {:command, {:git_accept_conflict, choice, start_line}}
    end
  end

  @spec action_ranges() :: [{Range.t(), MergeConflict.choice()}]
  defp action_ranges do
    {ranges, _col} =
      Enum.reduce(action_segments(), {[], 0}, fn %{text: text, choice: choice}, {ranges, col} ->
        width = String.length(text)
        start_col = col
        end_col = col + width - 1
        ranges = if choice, do: [{start_col..end_col, choice} | ranges], else: ranges
        {ranges, col + width}
      end)

    Enum.reverse(ranges)
  end
end
