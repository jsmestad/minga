defmodule MingaEditor.Renderer.MixedLayout do
  @moduledoc "Acquires the bounded source needed for a wrapped DisplayMap page."

  alias Minga.Buffer
  alias Minga.Buffer.RenderSnapshot
  alias Minga.Core.Decorations
  alias Minga.Core.WidthOracle
  alias MingaEditor.DisplayMap
  alias MingaEditor.FoldMap
  alias MingaEditor.Renderer.SearchHighlight
  alias MingaEditor.Renderer.TextInteractionIndex.Reader
  alias MingaEditor.Renderer.TextPresentation
  alias MingaEditor.Renderer.WrapLayout
  alias MingaEditor.Viewport

  @type preview :: MingaEditor.State.t() | MingaEditor.RenderPipeline.Input.t() | nil
  @type motion :: integer() | {:follow, non_neg_integer()}
  @type geometry :: {pos_integer(), WidthOracle.t(), Buffer.position()}
  @typep layout_result :: :stale | {:layout_changed, RenderSnapshot.t()}
  @typep request :: %{
           buffer: pid(),
           version: non_neg_integer(),
           layout_identity: tuple(),
           decorations: Decorations.t(),
           wrap_options: keyword(),
           show_invisible?: boolean(),
           preview: preview(),
           cursor_line: non_neg_integer(),
           purpose: :page | :bounds
         }

  @doc "Builds a render or hit-test page at the observed buffer version."
  @spec page(
          pid(),
          RenderSnapshot.t(),
          {FoldMap.t(), Decorations.t()},
          Viewport.t(),
          geometry(),
          motion(),
          preview(),
          TextPresentation.t() | nil
        ) ::
          {:ok, DisplayMap.t(), Viewport.t(), boolean(), [SearchHighlight.search_match()]}
          | :stale
  def page(
        buffer,
        snapshot,
        {fold_map, decorations},
        viewport,
        {width, oracle, {cursor_line, _} = cursor} = geometry,
        motion,
        preview,
        presentation \\ nil
      ) do
    basis = wrap_basis(snapshot, decorations, width, oracle, cursor_line, preview)

    {retained, _builds} =
      TextPresentation.matching_mixed_wrap(presentation, buffer, snapshot.version, basis)

    {projection, request} =
      prepare(buffer, snapshot, fold_map, decorations, geometry, preview, :page)

    {viewport, groups} = page_groups(projection, fold_map, viewport, cursor, motion)

    {missing, sources} = partition_groups(groups, retained)

    case fetch_missing(Enum.reverse(missing), request, sources) do
      {:ok, sources, preview_matches} ->
        motion = visual_motion(motion, projection, cursor, sources, request)

        {map, viewport, bottom?} =
          DisplayMap.visual_page(groups, fold_map, viewport, sources, motion)

        map = DisplayMap.with_measurement_metadata(map, basis, length(missing))
        {:ok, map, viewport, bottom?, preview_matches}

      {:layout_changed, _snapshot} ->
        :stale

      :stale ->
        :stale
    end
  end

  @doc "Advances mixed wheel bounds without fetching or expanding source groups with exact counts."
  @spec scroll(
          pid(),
          RenderSnapshot.t(),
          {FoldMap.t(), Decorations.t()},
          Viewport.t(),
          geometry(),
          integer(),
          preview(),
          {Reader.t() | nil, pos_integer()}
        ) :: {:ok, Viewport.t(), boolean()} | layout_result()
  def scroll(
        buffer,
        snapshot,
        {fold_map, decorations},
        viewport,
        {width, oracle, {cursor_line, _} = cursor} = geometry,
        delta,
        preview,
        {reader, window_id}
      ) do
    basis = wrap_basis(snapshot, decorations, width, oracle, cursor_line, preview)

    counts =
      if basis,
        do: Reader.windowed_wrap_counts(reader, window_id, buffer, snapshot.version, basis),
        else: %{}

    {projection, request} =
      prepare(buffer, snapshot, fold_map, decorations, geometry, preview, :bounds)

    {viewport, groups} = page_groups(projection, fold_map, viewport, cursor, delta)

    missing =
      for {line, :normal, _, _} = group <- groups, not Map.has_key?(counts, line), do: group

    with {:ok, counts, _} <- fetch_missing(missing, request, counts) do
      {viewport, bottom?} = DisplayMap.visual_scroll(groups, fold_map, viewport, counts, delta)
      {:ok, viewport, bottom?}
    end
  end

  defp partition_groups(groups, retained) do
    Enum.reduce(groups, {[], %{}}, fn {line, kind, _, _} = group, {missing, sources} ->
      case Map.get(retained, line) do
        {_, _, _, _, count} = source
        when (kind == :normal and count > 0) or (kind != :normal and count == 0) ->
          {missing, Map.put(sources, line, source)}

        _ ->
          {[group | missing], sources}
      end
    end)
  end

  defp wrap_basis(snapshot, decorations, width, oracle, cursor_line, nil) do
    # Derived blocks (including Inline Ask) and styling do not change a
    # source line's wrap. Project those independently on every page.
    base = snapshot.decorations

    virtual_text =
      if decorations.virtual_texts != base.virtual_texts, do: decorations.virtual_texts

    conceals =
      if decorations.conceal_ranges != base.conceal_ranges,
        do: {decorations.conceal_ranges, cursor_line}

    {:mixed, WrapLayout.basis(snapshot, width, oracle, cursor_line), virtual_text, conceals}
  end

  defp wrap_basis(_snapshot, _decorations, _width, _oracle, _cursor_line, _preview), do: nil

  defp prepare(buffer, snapshot, fold_map, decorations, geometry, preview, purpose) do
    {width, oracle, {cursor_line, _}} = geometry
    decorations = Decorations.build_vt_line_cache(decorations)
    projection = DisplayMap.project(fold_map, decorations, snapshot.line_count, width)

    request = %{
      buffer: buffer,
      version: snapshot.version,
      layout_identity: layout_identity(snapshot),
      decorations: decorations,
      wrap_options: WrapLayout.options(width, oracle, snapshot.options),
      show_invisible?: Map.get(snapshot.options, :show_invisible, false),
      preview: preview,
      cursor_line: cursor_line,
      purpose: purpose
    }

    {projection, request}
  end

  # If every group is retained, still qualify the answer against the live version.
  defp fetch_missing([], request, sources) do
    with {:ok, _snapshot} <- fetch_source(request, 0, 0) do
      {:ok, sources, []}
    end
  end

  defp fetch_missing(groups, request, sources),
    do: fetch_runs(groups, request, sources, [])

  defp page_groups(projection, fold_map, viewport, _cursor, delta) when is_integer(delta) do
    rows = Viewport.content_rows(viewport)
    top = FoldMap.visible_to_buffer(fold_map, viewport.top)
    before = rows - 1 + max(-delta, 0)
    after_count = rows + max(delta, 0)
    {viewport, DisplayMap.source_window(projection, top, before, after_count)}
  end

  defp page_groups(projection, fold_map, viewport, {cursor_line, _byte}, {:follow, _margin}) do
    rows = Viewport.content_rows(viewport)
    top = FoldMap.visible_to_buffer(fold_map, viewport.top)
    cursor_source = DisplayMap.visible_source(projection, cursor_line)
    groups = DisplayMap.source_window(projection, top, rows - 1, rows * 2)

    if List.keymember?(groups, cursor_source, 0) do
      {viewport, groups}
    else
      viewport = Viewport.put_top(viewport, FoldMap.buffer_to_visible(fold_map, cursor_source))
      {viewport, DisplayMap.source_window(projection, cursor_source, rows - 1, rows)}
    end
  end

  defp visual_motion(delta, _projection, _cursor, _sources, _request) when is_integer(delta),
    do: delta

  defp visual_motion({:follow, margin}, projection, {line, byte} = cursor, sources, request) do
    segment =
      case sources do
        %{^line => {text, _, composed, rows, count}} when is_integer(byte) and count > 1 ->
          WrapLayout.cursor_segment(
            text,
            composed,
            rows,
            request.decorations,
            cursor,
            Keyword.fetch!(request.wrap_options, :tab_width)
          )

        _ ->
          0
      end

    {DisplayMap.visible_source(projection, line), segment, margin}
  end

  @spec fetch_runs(
          [DisplayMap.group()],
          request(),
          DisplayMap.sources() | WrapLayout.counts(),
          [SearchHighlight.search_match()]
        ) ::
          {:ok, DisplayMap.sources() | WrapLayout.counts(), [SearchHighlight.search_match()]}
          | layout_result()
  defp fetch_runs([], _request, sources, matches),
    do: {:ok, sources, Enum.reverse(matches)}

  defp fetch_runs([{first, _, _, _} = group | rest], request, sources, matches) do
    # Coalesce consecutive visible source lines. Fold interiors never cross the process boundary.
    {run, rest, count} = take_run(rest, first + 1, [group], 1)

    with {:ok, snapshot} <- fetch_source(request, first, count) do
      {lines, preview_matches} =
        SearchHighlight.maybe_substitute_preview(request.preview, snapshot.lines, first)

      sources =
        measure_run(run, lines, snapshot.lines, snapshot.first_line_byte_offset, request, sources)

      fetch_runs(rest, request, sources, Enum.reverse(preview_matches, matches))
    end
  end

  defp fetch_source(request, first, count) do
    with {:ok, snapshot} <- Buffer.render_lines(request.buffer, request.version, first, count) do
      if layout_identity(snapshot) == request.layout_identity,
        do: {:ok, snapshot},
        else: {:layout_changed, snapshot}
    end
  end

  defp layout_identity(snapshot) do
    reveal_line =
      if Decorations.has_conceal_ranges?(snapshot.decorations), do: elem(snapshot.cursor, 0)

    {snapshot.options, snapshot.decorations.version, reveal_line}
  end

  defp take_run([{line, _, _, _} = group | rest], line, acc, count),
    do: take_run(rest, line + 1, [group | acc], count + 1)

  defp take_run(rest, _line, acc, count), do: {Enum.reverse(acc), rest, count}

  defp measure_run([], [], [], _offset, _request, sources), do: sources

  defp measure_run(
         [{line, kind, _, _} | groups],
         [text | rest],
         [raw | raw_rest],
         offset,
         request,
         sources
       ) do
    measurement = measure_group(text, line, kind, offset, request)
    sources = Map.put(sources, line, measurement)

    measure_run(
      groups,
      rest,
      raw_rest,
      offset + byte_size(raw) + 1,
      request,
      sources
    )
  end

  defp measure_group(text, line, :normal, _offset, %{purpose: :bounds} = request) do
    WrapLayout.row_count(
      text,
      line,
      request.decorations,
      request.cursor_line,
      request.wrap_options,
      request.show_invisible?
    )
  end

  defp measure_group(_text, _line, _fold, _offset, %{purpose: :bounds}), do: 0

  defp measure_group(text, line, :normal, offset, %{purpose: :page} = request) do
    {composed, rows} =
      WrapLayout.measure(
        text,
        line,
        request.decorations,
        request.wrap_options,
        request.show_invisible?,
        request.cursor_line
      )

    indexed = List.to_tuple(rows)
    {text, offset, composed, indexed, tuple_size(indexed)}
  end

  defp measure_group(text, _line, _fold, offset, %{purpose: :page}),
    do: {text, offset, text, {}, 0}
end
