defmodule MingaEditor.Mouse.HitTest do
  @moduledoc "Resolves mouse screen coordinates to editor targets."

  alias Minga.Buffer
  alias Minga.Core.Decorations
  alias Minga.Core.Unicode
  alias MingaEditor.DisplayMap
  alias MingaEditor.FoldMap
  alias MingaEditor.Layout
  alias MingaEditor.Mouse.Target.Buffer, as: BufferTarget
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  @type state :: EditorState.t()
  @type target :: {:buffer, BufferTarget.t()} | :miss
  @type position_result :: {:position, BufferTarget.position()} | :miss

  @spec resolve_buffer(state(), integer(), integer()) :: target()
  def resolve_buffer(_state, row, _col) when row < 0, do: :miss
  def resolve_buffer(_state, _row, col) when col < 0, do: :miss

  def resolve_buffer(state, row, col) do
    with %{id: id, window: window, buffer: buffer, content: content} <-
           window_context_at(state, row, col),
         {content_row, content_col, content_width, content_height} = content,
         total_lines = Buffer.line_count(buffer),
         gutter_width = buffer_gutter_width(buffer, total_lines),
         {cursor_line, _cursor_col} = window.cursor,
         top = scroll_top(window, content_height, content_width, cursor_line, buffer),
         local_row = row - content_row,
         local_col = max(col - content_col - gutter_width, 0),
         display_col = local_col + window.viewport.left,
         {:position, {line, target_col}} <-
           position(
             buffer,
             window,
             local_row,
             display_col,
             top,
             content_height,
             content_width,
             total_lines
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
    else
      _ -> :miss
    end
  catch
    :exit, _ -> :miss
  end

  @spec position(
          pid(),
          Window.t() | nil,
          integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          non_neg_integer()
        ) :: position_result()
  def position(_buf, _window, local_row, _local_col, _scroll_top, win_h, _content_w, _total_lines)
      when local_row < 0 or local_row >= win_h,
      do: :miss

  def position(buf, window, local_row, local_col, scroll_top, win_h, content_w, total_lines) do
    decs = Buffer.decorations(buf)
    fold_map = if window, do: window.fold_map, else: FoldMap.new()

    first_line = display_map_scroll_top(fold_map, scroll_top)

    case DisplayMap.compute(
           fold_map,
           decs,
           first_line,
           win_h,
           total_lines,
           content_text_width(buf, total_lines, content_w)
         ) do
      nil ->
        direct_position(buf, local_row, win_h, local_row + scroll_top, local_col, total_lines)

      %DisplayMap{} = display_map ->
        display_map_position(display_map, buf, local_row, local_col, win_h, total_lines)
    end
  catch
    :exit, _ ->
      direct_position(buf, local_row, win_h, local_row + scroll_top, local_col, total_lines)
  end

  @spec scroll_top(Window.t() | nil, pos_integer(), pos_integer(), non_neg_integer(), pid()) ::
          non_neg_integer()
  def scroll_top(%Window{viewport: viewport}, _height, _width, _cursor_line, _buffer),
    do: viewport.top

  def scroll_top(nil, content_height, content_width, cursor_line, buffer) do
    viewport = Viewport.new(content_height, content_width, 0)
    viewport = Viewport.scroll_to_cursor(viewport, {cursor_line, 0}, buffer)
    viewport.top
  end

  @spec buffer_gutter_width(pid() | nil, non_neg_integer()) :: non_neg_integer()
  def buffer_gutter_width(buffer, total_lines) do
    line_number_style = if buffer, do: Buffer.get_option(buffer, :line_numbers), else: :none

    Gutter.total_width(
      if line_number_style == :none, do: 0, else: Viewport.gutter_width(total_lines)
    )
  end

  @spec content_text_width(pid(), non_neg_integer(), pos_integer()) :: pos_integer()
  def content_text_width(buffer, total_lines, content_width),
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

    if EditorState.split?(state) do
      with {:ok, id, _rect} <-
             WindowTree.window_at(state.workspace.windows.tree, layout.editor_area, row, col) do
        context_from_window(state, layout, id, row, col)
      end
    else
      context_from_window(state, layout, state.workspace.windows.active, row, col)
    end
  end

  defp context_from_window(state, layout, id, row, col) do
    with %{content: content} <- Map.get(layout.window_layouts, id),
         true <- point_in_rect?(row, col, content),
         %Window{buffer: buffer} = window <- Map.get(state.workspace.windows.map, id),
         true <- is_pid(buffer) do
      %{id: id, window: window, buffer: buffer, content: content}
    else
      _ -> nil
    end
  end

  defp point_in_rect?(row, col, {rect_row, rect_col, width, height}) do
    row >= rect_row and row < rect_row + height and col >= rect_col and col < rect_col + width
  end

  defp display_map_scroll_top(%FoldMap{folds: []}, scroll_top), do: scroll_top

  defp display_map_scroll_top(fold_map, scroll_top),
    do: FoldMap.visible_to_buffer(fold_map, scroll_top)

  defp display_map_position(
         %DisplayMap{entries: entries},
         buffer,
         local_row,
         local_col,
         win_h,
         total_lines
       ) do
    case Enum.at(entries, local_row) do
      {_line, {:virtual_line, _}} ->
        :miss

      {_line, {:block, block, line_index}} ->
        click_block(block, line_index, local_col)

      {target_line, _entry_type} ->
        direct_position(buffer, local_row, win_h, target_line, local_col, total_lines)

      nil ->
        :miss
    end
  end

  defp click_block(block, line_index, col) do
    if block.on_click, do: block.on_click.(line_index, col)
    :miss
  end

  defp direct_position(_buffer, row, visible_rows, _line, _col, _total_lines)
       when row < 0 or row >= visible_rows,
       do: :miss

  defp direct_position(_buffer, _row, _visible_rows, target_line, _col, total_lines)
       when target_line < 0 or target_line >= total_lines,
       do: :miss

  defp direct_position(buffer, _row, _visible_rows, target_line, target_col, _total_lines) do
    adjusted_col = adjust_col_for_virtual_text(buffer, target_line, target_col)
    {:position, {target_line, clamp_col_to_line(buffer, target_line, adjusted_col)}}
  end

  defp adjust_col_for_virtual_text(buffer, line, display_col) do
    Decorations.display_col_to_buf_col(Buffer.decorations(buffer), line, display_col)
  catch
    :exit, _ -> display_col
  end
end
