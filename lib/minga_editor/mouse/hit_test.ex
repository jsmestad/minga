defmodule MingaEditor.Mouse.HitTest do
  @moduledoc "Resolves mouse screen coordinates to editor targets."

  alias Minga.Buffer
  alias Minga.Core.Decorations
  alias Minga.Core.Unicode
  alias MingaEditor.BufferDecorations
  alias MingaEditor.DisplayMap
  alias MingaEditor.FoldMap
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Layout
  alias MingaEditor.Mouse.Target.Buffer, as: BufferTarget
  alias MingaEditor.RenderModel.Window.Builder, as: WindowModelBuilder
  alias MingaEditor.RenderPipeline.ContentHelpers
  alias MingaEditor.Renderer.Context
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.Renderer.MixedLayout
  alias MingaEditor.Renderer.WrapLayout
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  @type state :: EditorState.t()
  @type target :: {:buffer, BufferTarget.t()} | {:command, term()} | :block_noop | :miss
  @type position_result ::
          {:position, BufferTarget.position()} | {:command, term()} | :block_noop | :miss
  @type click_target ::
          target()
          | {:window_fold, Window.id(), non_neg_integer()}
          | {:decoration_fold, pid(), reference()}
  @typep fold_position :: {:window_fold, non_neg_integer()} | {:decoration_fold, reference()}
  @typep row_result :: position_result() | fold_position()

  @spec resolve_buffer(state(), integer(), integer()) :: target()
  def resolve_buffer(state, row, col), do: resolve(state, row, col, :buffer)

  @doc "Resolves a plain press, including fold indicators in the fold gutter."
  @spec resolve_click(state(), integer(), integer()) :: click_target()
  def resolve_click(state, row, col), do: resolve(state, row, col, :click)

  defp resolve(_state, row, col, _mode) when row < 0 or col < 0, do: :miss

  defp resolve(state, row, col, mode) do
    with %{id: id, window: window, buffer: buffer, content: content} <-
           window_context_at(state, row, col),
         {content_row, content_col, content_width, content_height} = content,
         total_lines = Buffer.line_count(buffer),
         gutter_width = buffer_gutter_width(buffer, total_lines),
         {cursor_line, _cursor_col} = window.cursor,
         top = scroll_top(window, content_height, content_width, cursor_line, buffer),
         local_row = row - content_row,
         local_col = max(col - content_col - gutter_width, 0),
         fold_gutter? = mode == :click and col == content_col + Gutter.fold_column_offset(),
         position_result <-
           position_for_target(
             state,
             buffer,
             window,
             local_row,
             local_col,
             top,
             {content_height, content_width, total_lines},
             fold_gutter?
           ) do
      target_from_position_result(position_result, id, buffer, local_row, local_col, window)
    else
      _ -> :miss
    end
  catch
    :exit, _ -> :miss
  end

  @spec target_from_position_result(
          row_result(),
          term(),
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          Window.t()
        ) :: click_target()
  defp target_from_position_result(
         {:position, {line, target_col}},
         id,
         buffer,
         local_row,
         local_col,
         window
       ) do
    {:buffer,
     BufferTarget.new(%{
       window_id: id,
       buffer: buffer,
       line: line,
       col: target_col,
       local_row: local_row,
       local_col: local_col,
       viewport: window.viewport
     })}
  end

  defp target_from_position_result({:window_fold, line}, id, _buffer, _row, _col, _window),
    do: {:window_fold, id, line}

  defp target_from_position_result({:decoration_fold, id}, _win_id, buffer, _row, _col, _window),
    do: {:decoration_fold, buffer, id}

  defp target_from_position_result(
         {:command, command},
         _id,
         _buffer,
         _local_row,
         _local_col,
         _window
       ),
       do: {:command, command}

  defp target_from_position_result(:block_noop, _id, _buffer, _local_row, _local_col, _window),
    do: :block_noop

  defp target_from_position_result(:miss, _id, _buffer, _local_row, _local_col, _window),
    do: :miss

  @spec position(
          state() | nil,
          pid(),
          Window.t() | nil,
          integer(),
          non_neg_integer(),
          non_neg_integer(),
          {pos_integer(), pos_integer(), non_neg_integer()}
        ) :: position_result()
  def position(
        _state,
        _buf,
        _window,
        local_row,
        _visible_col,
        _scroll_top,
        {win_h, _content_w, _total_lines}
      )
      when local_row < 0 or local_row >= win_h,
      do: :miss

  def position(state, buf, window, local_row, visible_col, scroll_top, dimensions) do
    position_for_target(state, buf, window, local_row, visible_col, scroll_top, dimensions, false)
  end

  defp position_for_target(
         state,
         buf,
         window,
         local_row,
         visible_col,
         scroll_top,
         {win_h, content_w, total_lines},
         fold_gutter?
       ) do
    decs = decorations_for_position(state, buf)
    fold_map = if window, do: window.fold_map, else: FoldMap.new()
    display_col = visible_col + viewport_left(window)

    first_line = display_map_scroll_top(fold_map, scroll_top)
    text_width = content_text_width(buf, total_lines, content_w)

    params = %{
      local_row: local_row,
      win_h: win_h,
      scroll_top: scroll_top,
      display_col: display_col,
      text_width: text_width,
      total_lines: total_lines,
      fold_gutter?: fold_gutter?
    }

    if window != nil and DisplayMap.required?(fold_map, decs) and Buffer.get_option(buf, :wrap) do
      mixed_position(state, buf, window, visible_col, params)
    else
      case DisplayMap.compute(fold_map, decs, first_line, win_h, total_lines, text_width) do
        nil ->
          direct_or_wrapped_position(state, buf, window, params)

        %DisplayMap{entries: entries} ->
          entry = Enum.at(entries, local_row)

          fold_position(entry, window, fold_gutter?) ||
            display_map_position(
              entry,
              buf,
              local_row,
              visible_col,
              display_col,
              win_h,
              total_lines
            )
      end
    end
  catch
    :exit, _ ->
      direct_position(
        buf,
        local_row,
        win_h,
        local_row + scroll_top,
        visible_col + viewport_left(window),
        total_lines
      )
  end

  @spec viewport_left(Window.t() | nil) :: non_neg_integer()
  defp viewport_left(%Window{viewport: viewport}), do: viewport.left
  defp viewport_left(nil), do: 0

  @spec decorations_for_position(state() | nil, pid()) :: Decorations.t()
  defp decorations_for_position(nil, buf), do: Buffer.decorations(buf)
  defp decorations_for_position(state, buf), do: BufferDecorations.compose(state, buf)

  @spec scroll_top(Window.t() | nil, pos_integer(), pos_integer(), non_neg_integer(), pid()) ::
          non_neg_integer()
  def scroll_top(%Window{viewport: viewport}, _height, _width, _cursor_line, _buffer),
    do: viewport.top

  def scroll_top(nil, content_height, content_width, cursor_line, buffer) do
    viewport =
      Viewport.new(content_height, content_width, 0)
      |> Viewport.scroll_to_cursor({cursor_line, 0}, buffer)

    # Clamp to EOF so a click near the last line doesn't resolve through an
    # overscrolled top. Tolerate a dead buffer (same as Viewport.scroll_to_cursor/3's
    # internal scroll_margin lookup).
    case safe_line_count(buffer) do
      nil -> viewport.top
      total_lines -> Viewport.clamp_top_to_eof(viewport, total_lines).top
    end
  end

  @spec safe_line_count(pid()) :: pos_integer() | nil
  defp safe_line_count(buffer) do
    Buffer.line_count(buffer)
  catch
    :exit, _ -> nil
  end

  @spec buffer_gutter_width(pid() | nil, non_neg_integer()) :: non_neg_integer()
  def buffer_gutter_width(buffer, total_lines) do
    line_number_style = if buffer, do: Buffer.get_option(buffer, :line_numbers), else: :none

    Gutter.total_width(
      if line_number_style == :none, do: 0, else: Viewport.gutter_width(total_lines)
    )
  end

  @spec content_text_width(pid(), non_neg_integer(), pos_integer()) :: pos_integer()
  defp content_text_width(buffer, total_lines, content_width),
    do: max(content_width - buffer_gutter_width(buffer, total_lines), 1)

  @spec clamp_col_to_line(pid(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def clamp_col_to_line(buffer, line, col) do
    case Buffer.lines(buffer, line, 1) do
      [text] when byte_size(text) > 0 -> min(col, Unicode.last_grapheme_byte_offset(text))
      _ -> 0
    end
  end

  defp window_context_at(state, row, col) do
    layout = Layout.get(state)

    if MingaEditor.Session.State.split?(state.workspace) do
      with {:ok, id, _rect} <-
             WindowTree.window_at(state.workspace.windows.tree, layout.editor_area, row, col) do
        context_from_window(state, layout, id, row, col)
      end
    else
      context_from_window(state, layout, state.workspace.windows.active, row, col)
    end
  end

  defp context_from_window(state, layout, id, row, col) do
    with %{content: {r, c, w, h} = content}
         when row >= r and row < r + h and col >= c and col < c + w <-
           Map.get(layout.window_layouts, id),
         %Window{content: {:buffer, buffer}} = window when is_pid(buffer) <-
           Map.get(state.workspace.windows.map, id) do
      %{id: id, window: window, buffer: buffer, content: content}
    else
      _ -> nil
    end
  end

  defp display_map_scroll_top(%FoldMap{folds: []}, scroll_top), do: scroll_top

  defp display_map_scroll_top(fold_map, scroll_top),
    do: FoldMap.visible_to_buffer(fold_map, scroll_top)

  @spec fold_position(DisplayMap.entry() | nil, Window.t() | nil, boolean()) ::
          fold_position() | nil
  defp fold_position({line, {:fold_start, _hidden}}, _window, true),
    do: {:window_fold, line}

  defp fold_position({_line, {:decoration_fold, %{id: id}}}, _window, true),
    do: {:decoration_fold, id}

  defp fold_position({line, kind}, %Window{fold_ranges: ranges}, true)
       when kind == :normal or kind == {:wrapped, 0} do
    if Enum.any?(ranges, &(&1.start_line == line)), do: {:window_fold, line}
  end

  defp fold_position(_entry, _window, _fold_gutter?), do: nil

  defp display_map_position(
         entry,
         buffer,
         local_row,
         visible_col,
         display_col,
         win_h,
         total_lines
       ) do
    case entry do
      {_line, {:virtual_line, _}} ->
        :miss

      {_line, {:block, block, line_index}} ->
        click_block(block, line_index, visible_col)

      {target_line, _entry_type} ->
        direct_position(buffer, local_row, win_h, target_line, display_col, total_lines)

      nil ->
        :miss
    end
  end

  defp click_block(block, line_index, col) do
    case block.on_click && block.on_click.(line_index, col) do
      {:command, command} -> {:command, command}
      :ok -> :block_noop
      _other -> :miss
    end
  end

  @typep position_params :: %{
           required(:local_row) => integer(),
           required(:win_h) => pos_integer(),
           required(:scroll_top) => non_neg_integer(),
           required(:display_col) => non_neg_integer(),
           required(:text_width) => pos_integer(),
           required(:total_lines) => non_neg_integer(),
           required(:fold_gutter?) => boolean()
         }

  defp mixed_position(state, buffer, window, visible_col, params) do
    snapshot = Buffer.render_snapshot(buffer, 0, 0)
    {decorations, cursor, preview} = mixed_source(state, buffer, window, snapshot)
    width = params.text_width
    oracle = width_oracle(state)
    viewport = Viewport.fit_content(window.viewport, width, params.win_h)

    case MixedLayout.page(
           buffer,
           snapshot,
           {window.fold_map, decorations},
           viewport,
           {width, oracle, cursor},
           0,
           preview
         ) do
      {:ok, page, viewport, _bottom?, _matches} ->
        entry = Enum.at(page.entries, params.local_row)

        case fold_position(entry, window, params.fold_gutter?) do
          nil ->
            ctx = %Context{
              viewport: viewport,
              gutter_w:
                Gutter.total_width(Map.get(snapshot.options, :line_numbers), snapshot.line_count),
              content_w: width,
              decorations: decorations,
              cursor_line: elem(cursor, 0),
              tab_width: Map.get(snapshot.options, :tab_width, 2),
              show_invisible: Map.get(snapshot.options, :show_invisible, false),
              wrap_on: true,
              width_oracle: oracle
            }

            mixed_page_position(entry, page, buffer, visible_col, params, ctx)

          target ->
            target
        end

      :stale ->
        :miss
    end
  end

  defp mixed_source(nil, _buffer, _window, snapshot),
    do: {snapshot.decorations, snapshot.cursor, nil}

  defp mixed_source(state, buffer, window, snapshot) do
    decorations = BufferDecorations.compose(state, buffer, snapshot.decorations)

    if window.id == state.workspace.windows.active,
      do: {decorations, snapshot.cursor, state},
      else: {decorations, window.cursor, nil}
  end

  defp mixed_page_position(entry, page, buffer, col, params, ctx) do
    case entry do
      {line, {:wrapped, index}} ->
        source = DisplayMap.source(page, line)
        result = WindowModelBuilder.mixed_source_position(source, line, index, col, ctx)

        case result do
          {:ok, line, byte} ->
            buffer_position(
              buffer,
              params.local_row,
              params.win_h,
              line,
              byte,
              params.total_lines
            )

          :error ->
            :miss
        end

      entry ->
        display_map_position(
          entry,
          buffer,
          params.local_row,
          col,
          col,
          params.win_h,
          params.total_lines
        )
    end
  end

  @spec direct_or_wrapped_position(state() | nil, pid(), Window.t() | nil, position_params()) ::
          row_result()
  defp direct_or_wrapped_position(state, buf, %Window{} = window, params) do
    if Buffer.get_option(buf, :wrap) do
      wrapped_position(state, buf, window, params)
    else
      line = params.local_row + params.scroll_top

      target =
        if params.fold_gutter? and line < params.total_lines,
          do: fold_position({line, :normal}, window, true)

      target ||
        direct_position(
          buf,
          params.local_row,
          params.win_h,
          line,
          params.display_col,
          params.total_lines
        )
    end
  end

  defp direct_or_wrapped_position(_state, buf, _window, params) do
    direct_position(
      buf,
      params.local_row,
      params.win_h,
      params.local_row + params.scroll_top,
      params.display_col,
      params.total_lines
    )
  end

  @spec wrapped_position(state() | nil, pid(), Window.t(), position_params()) :: row_result()
  defp wrapped_position(_state, _buf, _window, %{local_row: local_row, win_h: win_h})
       when local_row < 0 or local_row >= win_h,
       do: :miss

  defp wrapped_position(state, buf, window, params) do
    viewport = Viewport.source_rows(window.viewport)
    visual_row = viewport.visual_row_offset + params.local_row
    fetch_count = max(params.win_h + viewport.visual_row_offset + 1, 1)
    snapshot = Buffer.render_snapshot(buf, params.scroll_top, fetch_count)
    ctx = wrapped_position_context(state, buf, window, snapshot, params.text_width)

    case wrapped_fold_position(window, params, visual_row, snapshot, ctx) do
      nil ->
        case WindowModelBuilder.wrapped_source_position(
               snapshot.lines,
               params.scroll_top,
               visual_row,
               params.display_col,
               ctx,
               snapshot.options
             ) do
          {:ok, line, col} ->
            buffer_position(buf, params.local_row, params.win_h, line, col, params.total_lines)

          :error ->
            :miss
        end

      target ->
        target
    end
  end

  defp wrapped_fold_position(
         %Window{fold_ranges: [_ | _]} = window,
         %{fold_gutter?: true, scroll_top: top},
         visual_row,
         snapshot,
         ctx
       ) do
    opts = WrapLayout.options(ctx.content_w, ctx.width_oracle, snapshot.options)
    cursor = {ctx.cursor_line || snapshot.line_count, nil}
    entry = wrapped_first_segment(snapshot.lines, top, visual_row, {ctx, opts, cursor})
    fold_position(entry, window, true)
  end

  defp wrapped_fold_position(_window, _params, _visual_row, _snapshot, _ctx), do: nil

  defp wrapped_first_segment([], _line, _visual_row, _layout), do: nil
  defp wrapped_first_segment([_ | _], line, 0, _layout), do: {line, {:wrapped, 0}}

  defp wrapped_first_segment([text | rest], line, visual_row, {ctx, opts, cursor} = layout) do
    {_, rows, _} =
      WrapLayout.measure(text, line, ctx.decorations, opts, ctx.show_invisible, cursor)

    count = length(rows)
    if visual_row >= count, do: wrapped_first_segment(rest, line + 1, visual_row - count, layout)
  end

  @spec wrapped_position_context(
          state() | nil,
          pid(),
          Window.t(),
          Minga.Buffer.RenderSnapshot.t(),
          pos_integer()
        ) :: Context.t()
  defp wrapped_position_context(state, buf, window, snapshot, text_width) do
    decorations = ContentHelpers.window_decorations(state, window, snapshot.decorations)
    options = snapshot.options

    %Context{
      viewport: window.viewport,
      gutter_w: buffer_gutter_width(buf, snapshot.line_count),
      content_w: text_width,
      decorations: decorations,
      tab_width: Map.get(options, :tab_width, 2),
      show_invisible: Map.get(options, :show_invisible, false),
      wrap_on: true,
      width_oracle: width_oracle(state)
    }
  end

  @spec width_oracle(state() | nil) :: Minga.Core.WidthOracle.t()
  defp width_oracle(%{frontend: %{capabilities: capabilities}}),
    do: Capabilities.width_oracle(capabilities)

  defp width_oracle(_state), do: %Minga.Core.WidthOracle.Monospace{}

  defp direct_position(_buffer, row, visible_rows, _line, _col, _total_lines)
       when row < 0 or row >= visible_rows,
       do: :miss

  defp direct_position(_buffer, _row, _visible_rows, target_line, _col, total_lines)
       when target_line < 0 or target_line >= total_lines,
       do: :miss

  defp direct_position(buffer, row, visible_rows, target_line, target_col, total_lines) do
    adjusted_col = adjust_col_for_virtual_text(buffer, target_line, target_col)
    buffer_position(buffer, row, visible_rows, target_line, adjusted_col, total_lines)
  end

  defp buffer_position(_buffer, row, visible_rows, _line, _col, _total_lines)
       when row < 0 or row >= visible_rows,
       do: :miss

  defp buffer_position(_buffer, _row, _visible_rows, target_line, _col, total_lines)
       when target_line < 0 or target_line >= total_lines,
       do: :miss

  defp buffer_position(buffer, _row, _visible_rows, target_line, target_col, _total_lines) do
    {:position, {target_line, clamp_col_to_line(buffer, target_line, target_col)}}
  end

  defp adjust_col_for_virtual_text(buffer, line, display_col) do
    line_len = line_length(buffer, line)
    Decorations.display_col_to_buf_col(Buffer.decorations(buffer), line, display_col, line_len)
  catch
    :exit, _ -> display_col
  end

  @spec line_length(pid(), non_neg_integer()) :: non_neg_integer() | :infinity
  defp line_length(buffer, line) do
    case Buffer.lines(buffer, line, 1) do
      [text] -> byte_size(text)
      _ -> :infinity
    end
  end
end
