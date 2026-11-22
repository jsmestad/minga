defmodule MingaEditor.Extension.GitDiff.View do
  @moduledoc false

  alias Minga.Core.Diff
  alias Minga.Core.DiffView
  alias MingaEditor.Extension.GitDiff.Hunk
  alias MingaEditor.Extension.GitDiff.Origin
  alias MingaEditor.Extension.GitDiff.Target

  @typep span :: {non_neg_integer(), non_neg_integer(), Diff.hunk()}
  @type t :: %{
          source_buf: pid() | nil,
          git_root: String.t(),
          rel_path: String.t(),
          section: Origin.section(),
          view_mode: Target.layout(),
          pane_width: pos_integer(),
          contents: Target.contents(),
          base_lines: [String.t()],
          current_lines: [String.t()],
          changes: [Diff.hunk()],
          line_metadata: [DiffView.line_meta()],
          hunk_lines: [non_neg_integer()],
          spans: tuple(),
          source_version: non_neg_integer() | nil
        }

  @spec build(
          Origin.t(),
          Target.contents(),
          non_neg_integer() | nil,
          Target.layout(),
          pos_integer()
        ) :: {t(), String.t()}
  def build(%Origin{} = origin, {base, current} = contents, version, layout, width) do
    base_lines = split_lines(base || "")
    current_lines = split_lines(current || "")

    project(
      %{
        source_buf: origin.source_buffer,
        git_root: origin.git_root,
        rel_path: origin.rel_path,
        section: origin.section,
        contents: contents,
        base_lines: base_lines,
        current_lines: current_lines,
        changes: Diff.diff_lines(base_lines, current_lines),
        source_version: version
      },
      layout,
      width
    )
  end

  @doc "Reprojects the same changes without comparing the source texts again."
  @spec reproject(t(), Target.layout(), pos_integer()) :: {t(), String.t()}
  def reproject(view, layout, width), do: project(view, layout, width)

  @spec origin(t()) :: Origin.t()
  def origin(view) do
    %Origin{
      git_root: view.git_root,
      rel_path: view.rel_path,
      section: view.section,
      source_buffer: view.source_buf
    }
  end

  @spec target(t(), non_neg_integer() | nil) :: Target.t()
  def target(view, row) do
    %Target{
      origin: origin(view),
      layout: view.view_mode,
      contents: view.contents,
      source_version: view.source_version,
      hunk: hunk_at(view, row)
    }
  end

  @spec destination(t(), non_neg_integer(), :next | :previous) :: non_neg_integer() | nil
  def destination(%{spans: spans}, row, :next) do
    spans |> first_after(row, 0, tuple_size(spans)) |> start_at(spans)
  end

  def destination(%{spans: spans}, row, :previous) do
    index = first_after(spans, row - 1, 0, tuple_size(spans)) - 1
    start_at(index, spans)
  end

  @spec reproject_cursor(t(), t(), {non_neg_integer(), non_neg_integer()}) ::
          {non_neg_integer(), non_neg_integer()}
  def reproject_cursor(%{spans: old}, %{spans: projected}, {row, _col} = cursor) do
    case span_at(old, row) do
      {index, {_first, _last, _change}} ->
        {first, _last, _change} = elem(projected, index)
        {first, 0}

      nil ->
        cursor
    end
  end

  @typep unprojected :: %{
           required(:source_buf) => pid() | nil,
           required(:git_root) => String.t(),
           required(:rel_path) => String.t(),
           required(:section) => Origin.section(),
           required(:contents) => Target.contents(),
           required(:base_lines) => [String.t()],
           required(:current_lines) => [String.t()],
           required(:changes) => [Diff.hunk()],
           required(:source_version) => non_neg_integer() | nil,
           optional(atom()) => term()
         }

  @spec project(unprojected(), Target.layout(), pos_integer()) :: {t(), String.t()}
  defp project(view, layout, width) do
    %{base_lines: base_lines, current_lines: current_lines, changes: changes} = view

    result =
      case layout do
        :unified ->
          DiffView.build_from_hunks(base_lines, current_lines, changes)

        :side_by_side ->
          DiffView.build_side_by_side_from_hunks(base_lines, current_lines, changes, width)
      end

    spans = index_spans(result.line_metadata, result.hunk_lines, changes, 0, nil, [])

    projected =
      Map.merge(view, %{
        view_mode: layout,
        pane_width: width,
        line_metadata: result.line_metadata,
        hunk_lines: result.hunk_lines,
        spans: spans
      })

    {projected, result.text}
  end

  @spec index_spans(
          [DiffView.line_meta()],
          [non_neg_integer()],
          [Diff.hunk()],
          non_neg_integer(),
          non_neg_integer() | nil,
          [span()]
        ) :: tuple()
  defp index_spans(_lines, [], [], _row, _start, spans) do
    spans |> Enum.reverse() |> List.to_tuple()
  end

  defp index_spans([_line | lines], [row | ends], [change | changes], row, start, spans) do
    index_spans(lines, ends, changes, row + 1, nil, [{start || row, row, change} | spans])
  end

  defp index_spans([line | lines], ends, changes, row, start, spans) do
    start = if line.type in [:added, :removed], do: start || row, else: start
    index_spans(lines, ends, changes, row + 1, start, spans)
  end

  @spec hunk_at(t(), non_neg_integer() | nil) :: Hunk.t() | nil
  defp hunk_at(_view, nil), do: nil

  defp hunk_at(%{spans: spans}, row) do
    case span_at(spans, row) do
      {index, {_first, _last, change}} ->
        %Hunk{
          index: index + 1,
          total: tuple_size(spans),
          change: change
        }

      nil ->
        nil
    end
  end

  @spec span_at(tuple(), non_neg_integer()) :: {non_neg_integer(), span()} | nil
  defp span_at(spans, row) do
    total = tuple_size(spans)
    index = last_at_or_after(spans, row, 0, total)

    if index < total do
      {first, _last, _change} = span = elem(spans, index)
      if first <= row, do: {index, span}
    end
  end

  @spec start_at(integer(), tuple()) :: non_neg_integer() | nil
  defp start_at(index, spans) when index >= 0 and index < tuple_size(spans) do
    {first, _last, _change} = elem(spans, index)
    first
  end

  defp start_at(_index, _spans), do: nil

  @spec first_after(tuple(), integer(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp first_after(_spans, _row, edge, edge), do: edge

  defp first_after(spans, row, lo, hi) do
    mid = div(lo + hi, 2)
    {first, _last, _change} = elem(spans, mid)

    if first > row,
      do: first_after(spans, row, lo, mid),
      else: first_after(spans, row, mid + 1, hi)
  end

  @spec last_at_or_after(tuple(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp last_at_or_after(_spans, _row, edge, edge), do: edge

  defp last_at_or_after(spans, row, lo, hi) do
    mid = div(lo + hi, 2)
    {_first, last, _change} = elem(spans, mid)

    if last >= row do
      last_at_or_after(spans, row, lo, mid)
    else
      last_at_or_after(spans, row, mid + 1, hi)
    end
  end

  @spec split_lines(String.t()) :: [String.t()]
  defp split_lines(""), do: []
  defp split_lines(content), do: String.split(content, "\n")
end
