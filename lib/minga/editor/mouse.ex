defmodule Minga.Editor.Mouse do
  @moduledoc """
  Mouse event handling for the editor.

  Handles scroll, click, drag, and release events, translating screen
  coordinates to buffer positions. All functions are pure `state → state`
  transformations; the buffer is mutated via `BufferServer` calls, but the
  GenServer state struct is returned unchanged or updated.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Buffer.Unicode
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Mouse, as: MouseState
  alias Minga.Editor.State.WhichKey, as: WhichKeyState
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.Mode
  alias Minga.Mode.VisualState
  alias Minga.Port.Protocol

  @scroll_lines 3

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc "Dispatches a mouse event, returning updated state."
  @spec handle(
          state(),
          integer(),
          integer(),
          Protocol.mouse_button(),
          Protocol.mouse_event_type()
        ) :: state()

  # Ignore mouse events when no buffer is open.
  def handle(%{buf: %{buffer: nil}} = state, _row, _col, _button, _type), do: state

  # Ignore mouse events when picker is open.
  def handle(%{picker_ui: %{picker: picker}} = state, _row, _col, _button, _type)
      when is_struct(picker, Minga.Picker),
      do: state

  # Ignore negative coordinates (can happen with pixel mouse before translation).
  def handle(state, row, _col, _button, _type) when row < 0, do: state
  def handle(state, _row, col, _button, _type) when col < 0, do: state

  # ── Scroll wheel ──

  def handle(%{buf: %{buffer: buf}, viewport: vp} = state, _row, _col, :wheel_down, :press) do
    total_lines = BufferServer.line_count(buf)
    new_vp = scroll_viewport(vp, @scroll_lines, total_lines)
    %{state | viewport: new_vp} |> clamp_cursor_to_viewport()
  end

  def handle(%{buf: %{buffer: buf}, viewport: vp} = state, _row, _col, :wheel_up, :press) do
    total_lines = BufferServer.line_count(buf)
    new_vp = scroll_viewport(vp, -@scroll_lines, total_lines)
    %{state | viewport: new_vp} |> clamp_cursor_to_viewport()
  end

  # ── Left click (press) — separator resize, window focus, or cursor move ──

  def handle(state, row, col, :left, :press) do
    state
    |> maybe_start_separator_drag(row, col)
    |> maybe_handle_content_click(row, col)
  end

  # ── Left drag — separator resize or visual selection ──

  def handle(
        %{mouse: %MouseState{resize_dragging: {:vertical, sep_pos}}} = state,
        _row,
        col,
        :left,
        :drag
      ) do
    handle_separator_drag(state, :vertical, sep_pos, col)
  end

  def handle(
        %{mouse: %MouseState{resize_dragging: {:horizontal, sep_pos}}} = state,
        row,
        _col,
        :left,
        :drag
      ) do
    handle_separator_drag(state, :horizontal, sep_pos, row)
  end

  def handle(
        %{mouse: %MouseState{dragging: true, anchor: anchor}} = state,
        row,
        col,
        :left,
        :drag
      ) do
    state =
      state
      |> maybe_auto_scroll(row)
      |> move_to_mouse_pos(row, col)

    # Enter visual mode on first drag movement
    enter_visual_if_needed(state, anchor)
  end

  # ── Left release — finalize separator resize, click, or drag ──

  def handle(%{mouse: %MouseState{resize_dragging: {_, _}}} = state, _row, _col, :left, :release) do
    %{state | mouse: MouseState.stop_resize(state.mouse)}
  end

  def handle(
        %{mouse: %MouseState{dragging: true}, mode: :visual} = state,
        _row,
        _col,
        :left,
        :release
      ) do
    %{state | mouse: MouseState.stop_drag(state.mouse)}
  end

  def handle(%{mouse: %MouseState{dragging: true}} = state, _row, _col, :left, :release) do
    %{state | mouse: MouseState.stop_drag(state.mouse)}
  end

  # Ignore all other mouse events (right click, middle click, motion, etc.)
  def handle(state, _row, _col, _button, _type), do: state

  # ── Separator resize helpers ──────────────────────────────────────────────

  # If the click is on a separator, start a resize drag and return state
  # with resize_dragging set. Otherwise return state unchanged.
  @spec maybe_start_separator_drag(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp maybe_start_separator_drag(%{window_tree: nil} = state, _row, _col), do: state

  defp maybe_start_separator_drag(state, row, col) do
    screen = EditorState.screen_rect(state)

    case WindowTree.separator_at(state.window_tree, screen, row, col) do
      {:ok, {dir, sep_pos}} ->
        %{state | mouse: MouseState.start_resize(state.mouse, dir, sep_pos)}

      :error ->
        state
    end
  end

  # If a resize drag was started, skip content click handling.
  @spec maybe_handle_content_click(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp maybe_handle_content_click(
         %{mouse: %MouseState{resize_dragging: {_, _}}} = state,
         _row,
         _col
       ),
       do: state

  defp maybe_handle_content_click(state, row, col), do: handle_content_click(state, row, col)

  @spec handle_separator_drag(state(), WindowTree.direction(), non_neg_integer(), integer()) ::
          state()
  defp handle_separator_drag(state, dir, sep_pos, new_pos) do
    screen = EditorState.screen_rect(state)

    case WindowTree.resize_at(state.window_tree, screen, dir, sep_pos, new_pos) do
      {:ok, new_tree} ->
        state = %{
          state
          | window_tree: new_tree,
            mouse: MouseState.update_resize(state.mouse, dir, new_pos)
        }

        resize_windows_to_layout(state)

      :error ->
        state
    end
  end

  @spec resize_windows_to_layout(state()) :: state()
  defp resize_windows_to_layout(state) do
    screen = EditorState.screen_rect(state)
    layouts = WindowTree.layout(state.window_tree, screen)

    Enum.reduce(layouts, state, fn {id, {_row, _col, width, height}}, acc ->
      EditorState.update_window(acc, id, &Window.resize(&1, height, width))
    end)
  end

  @spec handle_content_click(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp handle_content_click(state, row, col) do
    state = maybe_focus_window_at(state, row, col)

    case mouse_to_buffer_pos(state, row, col) do
      nil ->
        state

      {target_line, target_col} ->
        BufferServer.move_to(state.buf.buffer, {target_line, target_col})

        state = cancel_mode_for_mouse(state)

        %{
          state
          | mode: :normal,
            mode_state: Mode.initial_state(),
            mouse: MouseState.start_drag(state.mouse, {target_line, target_col})
        }
    end
  end

  # Focus the window under the mouse click (split mode only).
  @spec maybe_focus_window_at(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp maybe_focus_window_at(%{window_tree: nil} = state, _row, _col), do: state

  defp maybe_focus_window_at(state, row, col) do
    screen = EditorState.screen_rect(state)

    case WindowTree.window_at(state.window_tree, screen, row, col) do
      {:ok, id, _rect} -> EditorState.focus_window(state, id)
      :error -> state
    end
  end

  # Returns the gutter width for the current line_numbers setting.
  @spec gutter_width(state(), non_neg_integer()) :: non_neg_integer()
  defp gutter_width(state, total_lines) do
    if state.line_numbers == :none, do: 0, else: Viewport.gutter_width(total_lines)
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  # Scroll the viewport by `delta` lines without moving the cursor.
  # Clamps so the viewport doesn't scroll past the buffer.
  @spec scroll_viewport(Viewport.t(), integer(), non_neg_integer()) :: Viewport.t()
  defp scroll_viewport(%Viewport{} = vp, delta, total_lines) do
    visible_rows = Viewport.content_rows(vp)
    max_top = max(0, total_lines - visible_rows)
    new_top = (vp.top + delta) |> max(0) |> min(max_top)
    %Viewport{vp | top: new_top}
  end

  # Auto-scroll when dragging near viewport edges.
  @spec maybe_auto_scroll(state(), integer()) :: state()
  defp maybe_auto_scroll(%{buf: %{buffer: buf}, viewport: vp} = state, row) when row <= 0 do
    page_move(buf, vp, -1)
    state
  end

  defp maybe_auto_scroll(%{buf: %{buffer: buf}, viewport: vp} = state, row) do
    scroll_threshold = Viewport.content_rows(vp) - 1
    maybe_scroll_down(state, buf, vp, row, scroll_threshold)
  end

  defp maybe_scroll_down(state, buf, vp, row, threshold) when row >= threshold do
    page_move(buf, vp, 1)
    state
  end

  defp maybe_scroll_down(state, _buf, _vp, _row, _threshold), do: state

  # Move cursor to the buffer position corresponding to a screen coordinate.
  @spec move_to_mouse_pos(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp move_to_mouse_pos(state, row, col) do
    case mouse_to_buffer_pos(state, row, col) do
      nil ->
        state

      {line, col} ->
        BufferServer.move_to(state.buf.buffer, {line, col})
        state
    end
  end

  # Enters visual mode if not already in it (first drag movement).
  @spec enter_visual_if_needed(state(), {non_neg_integer(), non_neg_integer()}) :: state()
  defp enter_visual_if_needed(%{mode: :visual} = state, _anchor), do: state

  defp enter_visual_if_needed(state, anchor) do
    visual_state = %VisualState{visual_anchor: anchor, visual_type: :char}
    %{state | mode: :visual, mode_state: visual_state}
  end

  # Converts screen row/col to buffer position, or nil if the click is on
  # modeline, minibuffer, or beyond the buffer content (tilde rows).
  @spec mouse_to_buffer_pos(state(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp mouse_to_buffer_pos(state, row, col) do
    if EditorState.split?(state) do
      mouse_to_buffer_pos_split(state, row, col)
    else
      mouse_to_buffer_pos_single(state, row, col)
    end
  end

  @spec mouse_to_buffer_pos_single(state(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp mouse_to_buffer_pos_single(%{buf: %{buffer: buf}, viewport: vp} = state, row, col) do
    total_lines = BufferServer.line_count(buf)
    gutter_w = gutter_width(state, total_lines)
    visible_rows = Viewport.content_rows(vp)
    target_line = row + vp.top
    target_col = max(col - gutter_w, 0) + vp.left

    resolve_buffer_pos(buf, row, visible_rows, target_line, target_col, total_lines)
  end

  @spec mouse_to_buffer_pos_split(state(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp mouse_to_buffer_pos_split(state, row, col) do
    screen = EditorState.screen_rect(state)

    case WindowTree.window_at(state.window_tree, screen, row, col) do
      {:ok, id, {win_row, win_col, _win_w, win_h}} ->
        window = Map.fetch!(state.windows, id)
        buf = window.buffer
        total_lines = BufferServer.line_count(buf)
        gutter_w = gutter_width(state, total_lines)

        # Translate screen coords to window-local coords
        local_row = row - win_row
        local_col = max(col - win_col - gutter_w, 0)

        # Content rows = window height minus 1 for modeline
        visible_rows = max(win_h - 1, 1)

        # Compute scroll offset from the window's cursor (same as renderer)
        {cursor_line, _} = window.cursor
        scroll_top = split_scroll_top(win_h, cursor_line)
        target_line = local_row + scroll_top

        resolve_buffer_pos(buf, local_row, visible_rows, target_line, local_col, total_lines)

      :error ->
        nil
    end
  end

  # Computes the scroll top for a split window, given height and cursor line.
  # Reserves 1 row for the per-window modeline. Matches the renderer's
  # scroll_to_cursor_modeline_only logic (with a fresh viewport, top is always 0).
  @spec split_scroll_top(pos_integer(), non_neg_integer()) :: non_neg_integer()
  defp split_scroll_top(win_height, cursor_line) do
    visible_rows = max(win_height - 1, 1)

    if cursor_line >= visible_rows do
      cursor_line - visible_rows + 1
    else
      0
    end
  end

  # Click on modeline or minibuffer
  defp resolve_buffer_pos(_buf, row, visible_rows, _line, _col, _total)
       when row >= visible_rows,
       do: nil

  # Click on tilde row (beyond buffer content)
  defp resolve_buffer_pos(_buf, _row, _visible, target_line, _col, total)
       when target_line >= total,
       do: nil

  # Valid content area click
  defp resolve_buffer_pos(buf, _row, _visible, target_line, target_col, _total) do
    {target_line, clamp_col_to_line(buf, target_line, target_col)}
  end

  # Clamp cursor into the visible viewport after scrolling.
  @spec clamp_cursor_to_viewport(state()) :: state()
  defp clamp_cursor_to_viewport(%{buf: %{buffer: buf}, viewport: vp} = state) do
    {cursor_line, cursor_col} = BufferServer.cursor(buf)
    # Use the viewport directly — don't call scroll_to_cursor, which would
    # move the viewport back to the cursor and undo viewport-first scrolling.
    {first_line, last_line} = Viewport.visible_range(vp)

    do_clamp_cursor(state, buf, cursor_line, cursor_col, first_line, last_line)
  end

  defp do_clamp_cursor(state, buf, cursor_line, cursor_col, first_line, _last_line)
       when cursor_line < first_line do
    BufferServer.move_to(buf, {first_line, clamp_col_to_line(buf, first_line, cursor_col)})
    state
  end

  defp do_clamp_cursor(state, buf, cursor_line, cursor_col, _first_line, last_line)
       when cursor_line > last_line do
    BufferServer.move_to(buf, {last_line, clamp_col_to_line(buf, last_line, cursor_col)})
    state
  end

  defp do_clamp_cursor(state, _buf, _cursor_line, _cursor_col, _first_line, _last_line),
    do: state

  @spec clamp_col_to_line(pid(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp clamp_col_to_line(buf, line, col) do
    case BufferServer.get_lines(buf, line, 1) do
      [text] when byte_size(text) > 0 ->
        min(col, Unicode.last_grapheme_byte_offset(text))

      _ ->
        0
    end
  end

  # Cancel the current mode for mouse interaction (returns state ready for
  # visual mode entry).
  @spec cancel_mode_for_mouse(state()) :: state()
  defp cancel_mode_for_mouse(%{mode: :command} = state) do
    %{state | whichkey: WhichKeyState.clear(state.whichkey)}
  end

  defp cancel_mode_for_mouse(state), do: state

  # Move the cursor by `delta` lines (positive = down, negative = up),
  # clamping to buffer bounds.
  @spec page_move(pid(), Viewport.t(), integer()) :: :ok
  defp page_move(buf, _vp, delta) do
    {line, col} = BufferServer.cursor(buf)
    total_lines = BufferServer.line_count(buf)
    target_line = line + delta
    target_line = max(0, min(target_line, total_lines - 1))

    target_col =
      case BufferServer.get_lines(buf, target_line, 1) do
        [text] when byte_size(text) > 0 ->
          min(col, Unicode.last_grapheme_byte_offset(text))

        _ ->
          0
      end

    BufferServer.move_to(buf, {target_line, target_col})
  end
end
