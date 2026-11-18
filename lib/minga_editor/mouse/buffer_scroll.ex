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

  @spec advance_logical(Window.t(), pid(), integer()) :: {Window.t(), Buffer.position()}
  defp advance_logical(window, buffer, delta) do
    {Window.scroll_viewport(window, delta, Buffer.line_count(buffer)), Buffer.cursor(buffer)}
  end

  @spec advance_wrapped(State.t(), Window.t(), pid(), integer()) ::
          {Window.t(), Buffer.position()}
  defp advance_wrapped(state, window, buffer, delta) do
    source = Buffer.render_snapshot(buffer, 0, 0)

    if DisplayMap.required?(
         window.fold_map,
         BufferDecorations.compose(state, buffer, source.decorations)
       ) do
      {Window.scroll_viewport(window, delta, source.line_count), source.cursor}
    else
      viewport = pane_viewport(Layout.get(state), window)
      oracle = Capabilities.width_oracle(state.frontend.capabilities)
      width = text_width(viewport, source)
      rows = Viewport.content_rows(viewport)
      anchor = Viewport.vertical_anchor(viewport)

      active? = window.id == state.workspace.windows.active
      preview = if active? and SearchHighlight.substitute_preview?(state), do: state
      reader = if is_nil(preview), do: state.render.text_interaction_reader

      cursor_line =
        if active?,
          do: elem(source.cursor, 0),
          else: elem(window.cursor, 0)

      geometry = {width, oracle, cursor_line}

      case resident_anchor(
             reader,
             window.id,
             buffer,
             source,
             geometry,
             anchor,
             delta,
             rows
           ) do
        {:ok, {top, offset}, at_bottom?} ->
          viewport = Viewport.put_top_visual(viewport, top, offset, offset + 1)
          {install_viewport(window, viewport, delta, at_bottom?), source.cursor}

        :error ->
          advance_windowed(window, buffer, viewport, source, geometry, delta, rows, preview)
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
          RenderSnapshot.t(),
          {pos_integer(), WidthOracle.t(), non_neg_integer()},
          {non_neg_integer(), non_neg_integer()},
          integer(),
          pos_integer()
        ) ::
          {:ok, {non_neg_integer(), non_neg_integer()}, boolean()} | :error
  defp resident_anchor(nil, _id, _buffer, _snapshot, _geometry, _anchor, _delta, _rows),
    do: :error

  defp resident_anchor(
         reader,
         id,
         buffer,
         snapshot,
         {width, oracle, cursor_line},
         anchor,
         delta,
         rows
       ) do
    Reader.scroll_anchor(
      reader,
      id,
      buffer,
      snapshot.version,
      WrapLayout.basis(snapshot, width, oracle, cursor_line),
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
          {pos_integer(), WidthOracle.t(), non_neg_integer()},
          integer(),
          pos_integer(),
          State.t() | nil
        ) :: {Window.t(), Buffer.position()}
  defp advance_windowed(
         window,
         buffer,
         viewport,
         source,
         {width, oracle, cursor_line},
         delta,
         rows,
         preview
       ) do
    top = min(viewport.top, source.line_count - 1)
    first = max(top + min(delta, 0) - rows + 1, 0)
    last = min(top + max(delta, 0) + rows, source.line_count - 1)

    case Buffer.render_lines(buffer, source.version, first, last - first + 1) do
      {:ok, snapshot} ->
        {lines, _matches} =
          SearchHighlight.maybe_substitute_preview(preview, snapshot.lines, first)

        counts =
          snapshot |> WrapLayout.row_counts(width, oracle, cursor_line, lines) |> List.to_tuple()

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
