defmodule Minga.Editor.Mouse do
  @moduledoc """
  Mouse event handling for the editor.

  Handles scroll, click, drag, and release events, translating screen
  coordinates to buffer positions. All functions are pure `state -> state`
  transformations; the buffer is mutated via `BufferServer` calls, but the
  GenServer state struct is returned unchanged or updated.

  ## Multi-click selection

  * Double-click: select word under cursor, enter Visual mode
  * Triple-click: select entire line, enter Visual Line mode
  * Double-click + drag: extend selection word-by-word
  * Triple-click + drag: extend selection line-by-line

  ## Modifier clicks

  * Shift+click: extend visual selection to click position
  * Cmd/Super+click: go-to-definition (when LSP active)
  * Middle-click: paste at click position

  ## Horizontal scroll

  * Wheel left/right: shift viewport horizontally
  """

  import Bitwise

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Buffer.Unicode
  alias Minga.Editor.Layout
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Mouse, as: MouseState
  alias Minga.Editor.State.WhichKey, as: WhichKeyState
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.Mode
  alias Minga.Mode.VisualState

  @scroll_lines 3
  @scroll_cols 6

  # Modifier flags
  @mod_shift 0x01
  @mod_ctrl 0x02
  @mod_super 0x08

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc "Dispatches a mouse event, returning updated state."
  @spec handle(
          state(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: state()

  # Ignore mouse events when no buffer is open.
  def handle(%{buffers: %{active: nil}} = state, _row, _col, _button, _mods, _type, _cc),
    do: state

  # Ignore mouse events when picker is open.
  def handle(%{picker_ui: %{picker: picker}} = state, _r, _c, _b, _m, _t, _cc)
      when is_struct(picker, Minga.Picker),
      do: state

  # Ignore negative coordinates.
  def handle(state, row, _col, _button, _mods, _type, _cc) when row < 0, do: state
  def handle(state, _row, col, _button, _mods, _type, _cc) when col < 0, do: state

  # ── Scroll wheel (vertical) ──

  def handle(
        %{buffers: %{active: buf}, viewport: vp} = state,
        _r,
        _c,
        :wheel_down,
        _m,
        :press,
        _cc
      ) do
    total_lines = BufferServer.line_count(buf)
    new_vp = scroll_viewport(vp, @scroll_lines, total_lines)
    %{state | viewport: new_vp} |> clamp_cursor_to_viewport()
  end

  def handle(%{buffers: %{active: buf}, viewport: vp} = state, _r, _c, :wheel_up, _m, :press, _cc) do
    total_lines = BufferServer.line_count(buf)
    new_vp = scroll_viewport(vp, -@scroll_lines, total_lines)
    %{state | viewport: new_vp} |> clamp_cursor_to_viewport()
  end

  # ── Scroll wheel (horizontal) ──

  def handle(%{viewport: vp} = state, _r, _c, :wheel_right, _m, :press, _cc) do
    new_left = vp.left + @scroll_cols
    %{state | viewport: %{vp | left: new_left}}
  end

  def handle(%{viewport: vp} = state, _r, _c, :wheel_left, _m, :press, _cc) do
    new_left = max(vp.left - @scroll_cols, 0)
    %{state | viewport: %{vp | left: new_left}}
  end

  # ── Middle-click paste ──

  def handle(state, row, col, :middle, _mods, :press, _cc) do
    case mouse_to_buffer_pos(state, row, col) do
      nil ->
        state

      {target_line, target_col} ->
        BufferServer.move_to(state.buffers.active, {target_line, target_col})
        state = cancel_mode_for_mouse(state)
        state = %{state | mode: :normal, mode_state: Mode.initial_state()}
        Minga.Editor.dispatch_command(state, :paste_after)
    end
  end

  # ── Left click in the agent panel → focus input ──

  def handle(%{agent: %{panel: %{visible: true}}} = state, row, col, :left, mods, :press, cc)
      when row >= 0 do
    agent_panel_height = div(state.viewport.rows * 35, 100)
    editor_rows = state.viewport.rows - agent_panel_height

    if row >= editor_rows do
      %{state | agent: AgentState.focus_input(state.agent, true)}
    else
      state = %{state | agent: AgentState.focus_input(state.agent, false)}
      handle_left_press(state, row, col, mods, cc)
    end
  end

  # ── Left click (press) ──

  def handle(state, row, col, :left, mods, :press, cc) do
    handle_left_press(state, row, col, mods, cc)
  end

  # ── Left drag ──

  def handle(
        %{mouse: %MouseState{resize_dragging: {:vertical, sep_pos}}} = state,
        _row,
        col,
        :left,
        _mods,
        :drag,
        _cc
      ) do
    handle_separator_drag(state, :vertical, sep_pos, col)
  end

  def handle(
        %{mouse: %MouseState{resize_dragging: {:horizontal, sep_pos}}} = state,
        row,
        _col,
        :left,
        _mods,
        :drag,
        _cc
      ) do
    handle_separator_drag(state, :horizontal, sep_pos, row)
  end

  def handle(
        %{mouse: %MouseState{dragging: true, anchor: anchor, drag_click_count: dcc}} = state,
        row,
        col,
        :left,
        _mods,
        :drag,
        _cc
      ) do
    state =
      state
      |> maybe_auto_scroll(row)
      |> move_to_mouse_pos(row, col)

    case dcc do
      2 -> snap_selection_to_words(state, anchor)
      3 -> snap_selection_to_lines(state, anchor)
      _ -> enter_visual_if_needed(state, anchor)
    end
  end

  # ── Left release ──

  def handle(
        %{mouse: %MouseState{resize_dragging: {_, _}}} = state,
        _r,
        _c,
        :left,
        _m,
        :release,
        _cc
      ) do
    %{state | mouse: MouseState.stop_resize(state.mouse)}
  end

  def handle(
        %{mouse: %MouseState{dragging: true}, mode: :visual} = state,
        _r,
        _c,
        :left,
        _m,
        :release,
        _cc
      ) do
    %{state | mouse: MouseState.stop_drag(state.mouse)}
  end

  def handle(%{mouse: %MouseState{dragging: true}} = state, _r, _c, :left, _m, :release, _cc) do
    %{state | mouse: MouseState.stop_drag(state.mouse)}
  end

  # ── Mouse motion (hover tracking) ──

  def handle(state, row, col, :none, _mods, :motion, _cc) do
    %{state | mouse: MouseState.set_hover(state.mouse, row, col)}
  end

  # ── Ignore all other mouse events ──

  def handle(state, _row, _col, _button, _mods, _type, _cc), do: state

  # ── Left press dispatcher ──────────────────────────────────────────────────

  @spec handle_left_press(state(), integer(), integer(), non_neg_integer(), pos_integer()) ::
          state()
  defp handle_left_press(state, row, col, mods, native_click_count) do
    # Record press for multi-click detection
    mouse = MouseState.record_press(state.mouse, row, col, native_click_count)
    state = %{state | mouse: mouse}
    click_count = mouse.click_count

    # Check modifier clicks first
    handle_left_press_modifiers(state, row, col, mods, click_count)
  end

  @spec handle_left_press_modifiers(
          state(),
          integer(),
          integer(),
          non_neg_integer(),
          pos_integer()
        ) :: state()

  # Shift+click: extend selection
  defp handle_left_press_modifiers(state, row, col, mods, _cc) when band(mods, @mod_shift) != 0 do
    handle_shift_click(state, row, col)
  end

  # Cmd+click (GUI) or Ctrl+click (TUI): go-to-definition
  defp handle_left_press_modifiers(state, row, col, mods, _cc)
       when band(mods, @mod_super) != 0 or band(mods, @mod_ctrl) != 0 do
    handle_goto_definition_click(state, row, col)
  end

  # Double-click: word selection
  defp handle_left_press_modifiers(state, row, col, _mods, 2) do
    handle_double_click(state, row, col)
  end

  # Triple-click: line selection
  defp handle_left_press_modifiers(state, row, col, _mods, 3) do
    handle_triple_click(state, row, col)
  end

  # Single click: normal cursor positioning
  defp handle_left_press_modifiers(state, row, col, _mods, _cc) do
    state
    |> maybe_start_separator_drag(row, col)
    |> maybe_handle_content_click(row, col)
  end

  # ── Double-click: word selection ───────────────────────────────────────────

  @spec handle_double_click(state(), integer(), integer()) :: state()
  defp handle_double_click(state, row, col) do
    case mouse_to_buffer_pos(state, row, col) do
      nil ->
        state

      {line, buf_col} ->
        buf = state.buffers.active

        case word_boundaries_at(buf, line, buf_col) do
          {word_start, word_end} ->
            BufferServer.move_to(buf, {line, word_end})

            visual_state = %VisualState{
              visual_anchor: {line, word_start},
              visual_type: :char
            }

            %{
              state
              | mode: :visual,
                mode_state: visual_state,
                mouse: MouseState.start_drag(state.mouse, {line, word_start})
            }

          nil ->
            state
        end
    end
  end

  # ── Triple-click: line selection ───────────────────────────────────────────

  @spec handle_triple_click(state(), integer(), integer()) :: state()
  defp handle_triple_click(state, row, _col) do
    case mouse_to_buffer_line(state, row) do
      nil ->
        state

      line ->
        buf = state.buffers.active

        line_text =
          case BufferServer.get_lines(buf, line, 1) do
            [text] -> text
            _ -> ""
          end

        line_len = max(byte_size(line_text) - 1, 0)
        BufferServer.move_to(buf, {line, line_len})

        visual_state = %VisualState{
          visual_anchor: {line, 0},
          visual_type: :line
        }

        %{
          state
          | mode: :visual,
            mode_state: visual_state,
            mouse: MouseState.start_drag(state.mouse, {line, 0})
        }
    end
  end

  # ── Shift+click: extend selection ──────────────────────────────────────────

  @spec handle_shift_click(state(), integer(), integer()) :: state()
  defp handle_shift_click(state, row, col) do
    case mouse_to_buffer_pos(state, row, col) do
      nil ->
        state

      {target_line, target_col} ->
        buf = state.buffers.active

        # Get current cursor as anchor if not already in visual mode
        anchor =
          case state.mode do
            :visual ->
              state.mode_state.visual_anchor

            _ ->
              BufferServer.cursor(buf)
          end

        BufferServer.move_to(buf, {target_line, target_col})

        visual_state = %VisualState{
          visual_anchor: anchor,
          visual_type: :char
        }

        %{state | mode: :visual, mode_state: visual_state}
    end
  end

  # ── Cmd/Ctrl+click: go-to-definition ───────────────────────────────────────

  @spec handle_goto_definition_click(state(), integer(), integer()) :: state()
  defp handle_goto_definition_click(state, row, col) do
    case mouse_to_buffer_pos(state, row, col) do
      nil ->
        state

      {target_line, target_col} ->
        buf = state.buffers.active
        BufferServer.move_to(buf, {target_line, target_col})
        state = cancel_mode_for_mouse(state)
        state = %{state | mode: :normal, mode_state: Mode.initial_state()}
        Minga.Editor.dispatch_command(state, :goto_definition)
    end
  end

  # ── Word-by-word drag snapping ─────────────────────────────────────────────

  @spec snap_selection_to_words(
          state(),
          {non_neg_integer(), non_neg_integer()}
        ) :: state()
  defp snap_selection_to_words(state, anchor) do
    buf = state.buffers.active
    {cursor_line, cursor_col} = BufferServer.cursor(buf)

    # Snap cursor to word boundary
    case word_boundaries_at(buf, cursor_line, cursor_col) do
      {word_start, word_end} ->
        {anchor_line, _anchor_col} = anchor

        # If cursor is after anchor, extend to word end; otherwise to word start
        if {cursor_line, cursor_col} >= {anchor_line, 0} do
          BufferServer.move_to(buf, {cursor_line, word_end})
        else
          BufferServer.move_to(buf, {cursor_line, word_start})
        end

        enter_visual_if_needed(state, anchor)

      nil ->
        enter_visual_if_needed(state, anchor)
    end
  end

  # ── Line-by-line drag snapping ─────────────────────────────────────────────

  @spec snap_selection_to_lines(
          state(),
          {non_neg_integer(), non_neg_integer()}
        ) :: state()
  defp snap_selection_to_lines(state, {anchor_line, _anchor_col}) do
    buf = state.buffers.active
    {cursor_line, _cursor_col} = BufferServer.cursor(buf)

    # Extend selection to full lines
    if cursor_line >= anchor_line do
      # Dragging down: cursor at end of current line
      line_text =
        case BufferServer.get_lines(buf, cursor_line, 1) do
          [text] -> text
          _ -> ""
        end

      BufferServer.move_to(buf, {cursor_line, max(byte_size(line_text) - 1, 0)})
    else
      # Dragging up: cursor at start of current line
      BufferServer.move_to(buf, {cursor_line, 0})
    end

    visual_state = %VisualState{
      visual_anchor: {anchor_line, 0},
      visual_type: :line
    }

    %{state | mode: :visual, mode_state: visual_state}
  end

  # ── Word boundary detection ────────────────────────────────────────────────

  @spec word_boundaries_at(pid(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp word_boundaries_at(buf, line, col) do
    case BufferServer.get_lines(buf, line, 1) do
      [text] when byte_size(text) > 0 ->
        find_word_at(String.graphemes(text), col)

      _ ->
        nil
    end
  end

  @spec find_word_at([String.t()], non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp find_word_at([], _col), do: nil

  defp find_word_at(graphemes, col) do
    idx = min(col, length(graphemes) - 1)
    char = Enum.at(graphemes, idx)

    if word_char?(char) do
      {scan_word_start(graphemes, idx), scan_word_end(graphemes, idx)}
    else
      {idx, idx}
    end
  end

  @spec scan_word_start([String.t()], non_neg_integer()) :: non_neg_integer()
  defp scan_word_start(graphemes, idx) do
    if idx == 0 do
      0
    else
      prev = Enum.at(graphemes, idx - 1)

      if word_char?(prev) do
        scan_word_start(graphemes, idx - 1)
      else
        idx
      end
    end
  end

  @spec scan_word_end([String.t()], non_neg_integer()) :: non_neg_integer()
  defp scan_word_end(graphemes, idx) do
    if idx >= length(graphemes) - 1 do
      idx
    else
      next = Enum.at(graphemes, idx + 1)

      if word_char?(next) do
        scan_word_end(graphemes, idx + 1)
      else
        idx
      end
    end
  end

  @spec word_char?(String.t()) :: boolean()
  defp word_char?(char) do
    char =~ ~r/[\w]/u
  end

  # ── Separator resize helpers ──────────────────────────────────────────────

  @spec maybe_start_separator_drag(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp maybe_start_separator_drag(%{windows: %{tree: nil}} = state, _row, _col), do: state

  defp maybe_start_separator_drag(state, row, col) do
    screen = Layout.get(state).editor_area

    case WindowTree.separator_at(state.windows.tree, screen, row, col) do
      {:ok, {dir, sep_pos}} ->
        %{state | mouse: MouseState.start_resize(state.mouse, dir, sep_pos)}

      :error ->
        state
    end
  end

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
    screen = Layout.get(state).editor_area

    case WindowTree.resize_at(state.windows.tree, screen, dir, sep_pos, new_pos) do
      {:ok, new_tree} ->
        state = %{
          state
          | windows: %{state.windows | tree: new_tree},
            mouse: MouseState.update_resize(state.mouse, dir, new_pos)
        }

        resize_windows_to_layout(state)

      :error ->
        state
    end
  end

  @spec resize_windows_to_layout(state()) :: state()
  defp resize_windows_to_layout(state) do
    layout = Layout.get(state)

    Enum.reduce(layout.window_layouts, state, fn {id, wl}, acc ->
      {_r, _c, width, height} = wl.total
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
        BufferServer.move_to(state.buffers.active, {target_line, target_col})

        state = cancel_mode_for_mouse(state)

        %{
          state
          | mode: :normal,
            mode_state: Mode.initial_state(),
            mouse: MouseState.start_drag(state.mouse, {target_line, target_col})
        }
    end
  end

  @spec maybe_focus_window_at(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp maybe_focus_window_at(%{windows: %{tree: nil}} = state, _row, _col), do: state

  defp maybe_focus_window_at(state, row, col) do
    screen = Layout.get(state).editor_area

    case WindowTree.window_at(state.windows.tree, screen, row, col) do
      {:ok, id, _rect} -> EditorState.focus_window(state, id)
      :error -> state
    end
  end

  @spec gutter_width(state(), non_neg_integer()) :: non_neg_integer()
  defp gutter_width(state, total_lines) do
    if state.line_numbers == :none, do: 0, else: Viewport.gutter_width(total_lines)
  end

  # ── Screen-to-buffer coordinate translation ────────────────────────────────

  @spec mouse_to_buffer_pos(state(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp mouse_to_buffer_pos(state, row, col) do
    if EditorState.split?(state) do
      mouse_to_buffer_pos_split(state, row, col)
    else
      mouse_to_buffer_pos_single(state, row, col)
    end
  end

  # Like mouse_to_buffer_pos but only returns the line (for triple-click).
  @spec mouse_to_buffer_line(state(), non_neg_integer()) :: non_neg_integer() | nil
  defp mouse_to_buffer_line(%{buffers: %{active: buf}, viewport: vp} = _state, row) do
    total_lines = BufferServer.line_count(buf)
    visible_rows = Viewport.content_rows(vp)
    target_line = row + vp.top

    if row >= visible_rows or target_line >= total_lines do
      nil
    else
      target_line
    end
  end

  @spec mouse_to_buffer_pos_single(state(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp mouse_to_buffer_pos_single(%{buffers: %{active: buf}, viewport: vp} = state, row, col) do
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
    screen = Layout.get(state).editor_area

    case WindowTree.window_at(state.windows.tree, screen, row, col) do
      {:ok, id, {win_row, win_col, _win_w, win_h}} ->
        window = Map.fetch!(state.windows.map, id)
        buf = window.buffer
        total_lines = BufferServer.line_count(buf)
        gutter_w = gutter_width(state, total_lines)
        local_row = row - win_row
        local_col = max(col - win_col - gutter_w, 0)
        visible_rows = max(win_h - 1, 1)
        {cursor_line, _} = window.cursor
        scroll_top = split_scroll_top(win_h, cursor_line)
        target_line = local_row + scroll_top

        resolve_buffer_pos(buf, local_row, visible_rows, target_line, local_col, total_lines)

      :error ->
        nil
    end
  end

  @spec split_scroll_top(pos_integer(), non_neg_integer()) :: non_neg_integer()
  defp split_scroll_top(win_height, cursor_line) do
    visible_rows = max(win_height - 1, 1)

    if cursor_line >= visible_rows do
      cursor_line - visible_rows + 1
    else
      0
    end
  end

  defp resolve_buffer_pos(_buf, row, visible_rows, _line, _col, _total)
       when row >= visible_rows,
       do: nil

  defp resolve_buffer_pos(_buf, _row, _visible, target_line, _col, total)
       when target_line >= total,
       do: nil

  defp resolve_buffer_pos(buf, _row, _visible, target_line, target_col, _total) do
    {target_line, clamp_col_to_line(buf, target_line, target_col)}
  end

  # ── Viewport helpers ───────────────────────────────────────────────────────

  @spec scroll_viewport(Viewport.t(), integer(), non_neg_integer()) :: Viewport.t()
  defp scroll_viewport(%Viewport{} = vp, delta, total_lines) do
    visible_rows = Viewport.content_rows(vp)
    max_top = max(0, total_lines - visible_rows)
    new_top = (vp.top + delta) |> max(0) |> min(max_top)
    %Viewport{vp | top: new_top}
  end

  @spec clamp_cursor_to_viewport(state()) :: state()
  defp clamp_cursor_to_viewport(%{buffers: %{active: buf}, viewport: vp} = state) do
    {cursor_line, cursor_col} = BufferServer.cursor(buf)
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

  @spec maybe_auto_scroll(state(), integer()) :: state()
  defp maybe_auto_scroll(%{buffers: %{active: buf}, viewport: vp} = state, row) when row <= 0 do
    page_move(buf, vp, -1)
    state
  end

  defp maybe_auto_scroll(%{buffers: %{active: buf}, viewport: vp} = state, row) do
    scroll_threshold = Viewport.content_rows(vp) - 1
    maybe_scroll_down(state, buf, vp, row, scroll_threshold)
  end

  defp maybe_scroll_down(state, buf, vp, row, threshold) when row >= threshold do
    page_move(buf, vp, 1)
    state
  end

  defp maybe_scroll_down(state, _buf, _vp, _row, _threshold), do: state

  @spec move_to_mouse_pos(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp move_to_mouse_pos(state, row, col) do
    case mouse_to_buffer_pos(state, row, col) do
      nil ->
        state

      {line, c} ->
        BufferServer.move_to(state.buffers.active, {line, c})
        state
    end
  end

  @spec enter_visual_if_needed(state(), {non_neg_integer(), non_neg_integer()}) :: state()
  defp enter_visual_if_needed(%{mode: :visual} = state, _anchor), do: state

  defp enter_visual_if_needed(state, anchor) do
    visual_state = %VisualState{visual_anchor: anchor, visual_type: :char}
    %{state | mode: :visual, mode_state: visual_state}
  end

  @spec clamp_col_to_line(pid(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp clamp_col_to_line(buf, line, col) do
    case BufferServer.get_lines(buf, line, 1) do
      [text] when byte_size(text) > 0 ->
        min(col, Unicode.last_grapheme_byte_offset(text))

      _ ->
        0
    end
  end

  @spec cancel_mode_for_mouse(state()) :: state()
  defp cancel_mode_for_mouse(%{mode: :command} = state) do
    %{state | whichkey: WhichKeyState.clear(state.whichkey)}
  end

  defp cancel_mode_for_mouse(state), do: state

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
