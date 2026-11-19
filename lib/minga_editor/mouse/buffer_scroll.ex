defmodule MingaEditor.Mouse.BufferScroll do
  @moduledoc "Resolves wheel movement against the target buffer pane without moving the cursor."

  alias Minga.Buffer
  alias Minga.Buffer.RenderSnapshot
  alias Minga.Core.WidthOracle
  alias MingaEditor.BufferDecorations
  alias MingaEditor.DisplayMap
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Layout
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.Renderer.MixedLayout
  alias MingaEditor.Renderer.SearchHighlight
  alias MingaEditor.Renderer.TextInteractionIndex.Reader
  alias MingaEditor.Renderer.WrapLayout
  alias MingaEditor.State
  alias MingaEditor.Viewport
  alias MingaEditor.Window

  @spec advance(State.t(), Window.t(), pid(), integer()) :: {Window.t(), Buffer.position()}
  def advance(state, window, buffer, delta) do
    case Buffer.get_option(buffer, :wrap) do
      true -> advance_wrapped(state, window, buffer, delta)
      _ -> advance_logical(window, buffer, delta)
    end
  end

  @doc "Installs a visual scrollbar target only when its displayed layout is still current."
  @spec seek_resident(State.t(), Window.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, Window.t()} | :error
  def seek_resident(
        %{render: %{text_interaction_reader: reader}} = state,
        %Window{content: {:buffer, buffer}} = window,
        presentation_id,
        rank
      )
      when is_pid(buffer) and not is_nil(reader) do
    snapshot = Buffer.render_snapshot(buffer, 0, 0)
    active? = window.id == state.workspace.windows.active
    decorations = BufferDecorations.compose(state, buffer, snapshot.decorations)

    if Map.get(snapshot.options, :wrap) and not DisplayMap.required?(window.fold_map, decorations) and
         not (active? and SearchHighlight.substitute_preview?(state)) do
      seek_wrapped_rank(state, window, presentation_id, rank, reader, buffer, snapshot, active?)
    else
      :error
    end
  end

  def seek_resident(_state, _window, _presentation_id, _rank), do: :error

  @spec seek_wrapped_rank(
          State.t(),
          Window.t(),
          non_neg_integer(),
          non_neg_integer(),
          Reader.t(),
          pid(),
          RenderSnapshot.t(),
          boolean()
        ) :: {:ok, Window.t()} | :error
  defp seek_wrapped_rank(state, window, presentation_id, rank, reader, buffer, snapshot, active?) do
    viewport = pane_viewport(Layout.get(state), window)
    oracle = Capabilities.width_oracle(state.frontend.capabilities)
    cursor_line = if active?, do: elem(snapshot.cursor, 0), else: elem(window.cursor, 0)
    basis = WrapLayout.basis(snapshot, text_width(viewport, snapshot), oracle, cursor_line)
    fitted = Viewport.content_rows(viewport)

    case Reader.seek_scroll_rank(
           reader,
           window.id,
           presentation_id,
           {buffer, snapshot.version, basis, Window.authoritative_scroll_seq(window)},
           rank,
           fitted
         ) do
      {:ok, {top, offset}, at_bottom?} ->
        viewport = Viewport.put_top_visual(viewport, top, offset, offset + 1)

        window =
          window
          |> Window.set_viewport(viewport)
          |> Window.set_pinned(at_bottom?)
          |> Window.mark_scroll_echo()
          |> Window.record_scroll_event(System.monotonic_time(:millisecond), snapshot.cursor)

        {:ok, window}

      :error ->
        :error
    end
  end

  @spec advance_logical(Window.t(), pid(), integer()) :: {Window.t(), Buffer.position()}
  defp advance_logical(window, buffer, delta) do
    {Window.scroll_viewport(window, delta, Buffer.line_count(buffer)), Buffer.cursor(buffer)}
  end

  @spec advance_wrapped(State.t(), Window.t(), pid(), integer()) ::
          {Window.t(), Buffer.position()}
  defp advance_wrapped(state, window, buffer, delta) do
    advance_wrapped(state, window, buffer, delta, Buffer.render_snapshot(buffer, 0, 0), true)
  end

  defp advance_wrapped(state, window, buffer, delta, source, retry?) do
    decorations = BufferDecorations.compose(state, buffer, source.decorations)
    viewport = pane_viewport(Layout.get(state), window)
    oracle = Capabilities.width_oracle(state.frontend.capabilities)
    width = text_width(viewport, source)
    active? = window.id == state.workspace.windows.active
    cursor = if active?, do: source.cursor, else: window.cursor
    preview = if active? and SearchHighlight.substitute_preview?(state), do: state

    if DisplayMap.required?(window.fold_map, decorations) do
      case MixedLayout.scroll(
             buffer,
             source,
             {window.fold_map, decorations},
             viewport,
             {width, oracle, cursor},
             delta,
             preview,
             {state.render.text_interaction_reader, window.id}
           ) do
        {:ok, viewport, at_bottom?} ->
          {install_viewport(window, viewport, delta, at_bottom?), source.cursor}

        {:layout_changed, snapshot} when retry? ->
          advance_wrapped(state, window, buffer, delta, snapshot, false)

        {:layout_changed, snapshot} ->
          {window, snapshot.cursor}

        :stale ->
          {window, source.cursor}
      end
    else
      viewport = Viewport.source_rows(viewport)
      reader = if is_nil(preview), do: state.render.text_interaction_reader
      rows = Viewport.content_rows(viewport)
      anchor = Viewport.vertical_anchor(viewport)
      cursor_line = elem(cursor, 0)
      geometry = {oracle, active?}
      basis = WrapLayout.basis(source, width, oracle, cursor_line)

      case resident_anchor(
             reader,
             window.id,
             buffer,
             source.version,
             basis,
             anchor,
             delta,
             rows
           ) do
        {:ok, {top, offset}, at_bottom?} ->
          viewport = Viewport.put_top_visual(viewport, top, offset, offset + 1)
          {install_viewport(window, viewport, delta, at_bottom?), source.cursor}

        :error ->
          advance_windowed(
            window,
            buffer,
            viewport,
            source,
            geometry,
            delta,
            rows,
            {preview, reader}
          )
      end
    end
  end

  @spec pane_viewport(Layout.t(), Window.t()) :: Viewport.t()
  defp pane_viewport(layout, window) do
    case Map.get(layout.window_layouts, window.id) do
      %{content: {_row, _col, width, height}} ->
        Viewport.fit_content(window.viewport, width, height)

      nil ->
        window.viewport
    end
  end

  @spec text_width(Viewport.t(), RenderSnapshot.t()) :: pos_integer()
  defp text_width(viewport, snapshot) do
    gutter = Gutter.total_width(Map.get(snapshot.options, :line_numbers), snapshot.line_count)
    max(viewport.cols - gutter, 1)
  end

  @spec resident_anchor(
          Reader.t() | nil,
          Window.id(),
          pid(),
          non_neg_integer(),
          tuple(),
          {non_neg_integer(), non_neg_integer()},
          integer(),
          pos_integer()
        ) ::
          {:ok, {non_neg_integer(), non_neg_integer()}, boolean()} | :error
  defp resident_anchor(nil, _id, _buffer, _version, _basis, _anchor, _delta, _rows),
    do: :error

  defp resident_anchor(
         reader,
         id,
         buffer,
         version,
         basis,
         anchor,
         delta,
         rows
       ) do
    Reader.scroll_anchor(
      reader,
      id,
      buffer,
      version,
      basis,
      anchor,
      delta,
      rows
    )
  end

  @spec advance_windowed(
          Window.t(),
          pid(),
          Viewport.t(),
          RenderSnapshot.t(),
          {WidthOracle.t(), boolean()},
          integer(),
          pos_integer(),
          {State.t() | nil, Reader.t() | nil}
        ) :: {Window.t(), Buffer.position()}
  defp advance_windowed(
         window,
         buffer,
         viewport,
         source,
         {oracle, active?},
         delta,
         rows,
         {preview, reader}
       ) do
    top = min(viewport.top, source.line_count - 1)
    first = max(top + min(delta, 0) - rows + 1, 0)
    last = min(top + max(delta, 0) + rows, source.line_count - 1)

    case Buffer.render_lines(buffer, source.version, first, last - first + 1) do
      {:ok, snapshot} ->
        width = text_width(viewport, snapshot)
        cursor_line = if active?, do: elem(snapshot.cursor, 0), else: elem(window.cursor, 0)
        basis = WrapLayout.basis(snapshot, width, oracle, cursor_line)

        retained_counts =
          Reader.windowed_wrap_counts(reader, window.id, buffer, snapshot.version, basis)

        {lines, _matches} =
          SearchHighlight.maybe_substitute_preview(preview, snapshot.lines, first)

        counts =
          snapshot
          |> WrapLayout.row_counts(width, oracle, cursor_line, lines, retained_counts)
          |> List.to_tuple()

        {viewport, at_bottom?} =
          Viewport.scroll_visual_rows(viewport, delta, snapshot.line_count, fn line ->
            elem(counts, line - first)
          end)

        {install_viewport(window, viewport, delta, at_bottom?), snapshot.cursor}

      :stale ->
        {window, source.cursor}
    end
  end

  @spec install_viewport(Window.t(), Viewport.t(), integer(), boolean()) :: Window.t()
  defp install_viewport(window, viewport, delta, at_bottom?) do
    window |> Window.set_viewport(viewport) |> Window.set_pinned(delta > 0 and at_bottom?)
  end
end
