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

  alias Minga.Buffer.Decorations
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Buffer.Unicode
  alias Minga.Config.Options
  alias Minga.Editor.DisplayMap
  alias Minga.Editor.FoldMap
  alias Minga.Editor.Layout
  alias Minga.Editor.Renderer.Gutter
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Mouse, as: MouseState
  alias Minga.Editor.State.WhichKey, as: WhichKeyState
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree

  alias Minga.Mode.VisualState
  alias Minga.Port.Capabilities

  # TUI scrolls 3 lines per wheel tick (standard terminal behavior).
  # GUI scrolls 1 line per event because the frontend accumulates pixel
  # deltas and emits one event per cellHeight crossed.
  @gui_scroll_lines 1
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
  def handle(
        %{workspace: %{buffers: %{active: nil}}} = state,
        _row,
        _col,
        _button,
        _mods,
        _type,
        _cc
      ),
      do: state

  # Ignore negative coordinates.
  def handle(state, row, _col, _button, _mods, _type, _cc) when row < 0, do: state
  def handle(state, _row, col, _button, _mods, _type, _cc) when col < 0, do: state

  # ── Scroll wheel (vertical) ──

  def handle(
        %{workspace: %{buffers: %{active: buf}}} = state,
        _r,
        _c,
        :wheel_down,
        _m,
        :press,
        _cc
      ) do
    total_lines = BufferServer.line_count(buf)
    lines = scroll_lines(state)
    vp = active_window_viewport(state)
    new_vp = scroll_viewport(vp, lines, total_lines)
    put_active_window_viewport(state, new_vp) |> clamp_cursor_to_viewport(:down)
  end

  def handle(%{workspace: %{buffers: %{active: buf}}} = state, _r, _c, :wheel_up, _m, :press, _cc) do
    total_lines = BufferServer.line_count(buf)
    lines = scroll_lines(state)
    vp = active_window_viewport(state)
    new_vp = scroll_viewport(vp, -lines, total_lines)
    put_active_window_viewport(state, new_vp) |> clamp_cursor_to_viewport(:up)
  end

  # ── Scroll wheel (horizontal) ──

  def handle(state, _r, _c, :wheel_right, _m, :press, _cc) do
    vp = active_window_viewport(state)
    new_left = vp.left + @scroll_cols
    put_active_window_viewport(state, %{vp | left: new_left})
  end

  def handle(state, _r, _c, :wheel_left, _m, :press, _cc) do
    vp = active_window_viewport(state)
    new_left = max(vp.left - @scroll_cols, 0)
    put_active_window_viewport(state, %{vp | left: new_left})
  end

  # ── Middle-click paste ──

  def handle(state, row, col, :middle, _mods, :press, _cc) do
    # Middle-click on tab bar closes the clicked tab
    case tab_bar_click(state, row, col) do
      {:command, _cmd} ->
        close_tab_at(state, row, col)

      :not_tab_bar ->
        case mouse_to_buffer_pos(state, row, col) do
          nil ->
            state

          {target_line, target_col} ->
            BufferServer.move_to(state.workspace.buffers.active, {target_line, target_col})
            state = cancel_mode_for_mouse(state)
            state = EditorState.transition_mode(state, :normal)
            Minga.Editor.dispatch_command(state, :paste_after)
        end
    end
  end

  # ── Left click (press) ──
  # Agent-region clicks are intercepted by Input.AgentMouse before
  # reaching this handler. This clause handles buffer-content clicks only.

  def handle(state, row, col, :left, mods, :press, cc) do
    handle_left_press(state, row, col, mods, cc)
  end

  # ── Left drag ──

  def handle(
        %{workspace: %{mouse: %MouseState{resize_dragging: {:vertical, sep_pos}}}} = state,
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
        %{workspace: %{mouse: %MouseState{resize_dragging: {:horizontal, sep_pos}}}} = state,
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
        %{workspace: %{mouse: %MouseState{dragging: true, anchor: anchor, drag_click_count: dcc}}} =
          state,
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
        %{workspace: %{mouse: %MouseState{resize_dragging: {_, _}}}} = state,
        _r,
        _c,
        :left,
        _m,
        :release,
        _cc
      ) do
    %{
      state
      | workspace: %{state.workspace | mouse: MouseState.stop_resize(state.workspace.mouse)}
    }
  end

  def handle(
        %{workspace: %{mouse: %MouseState{dragging: true}, vim: %{mode: :visual}}} = state,
        _r,
        _c,
        :left,
        _m,
        :release,
        _cc
      ) do
    state = %{
      state
      | workspace: %{state.workspace | mouse: MouseState.stop_drag(state.workspace.mouse)}
    }

    # Auto-copy selection to system clipboard on mouse release.
    # Standard terminal behavior: selecting text copies it.
    auto_copy_selection(state)
  end

  def handle(
        %{workspace: %{mouse: %MouseState{dragging: true}}} = state,
        _r,
        _c,
        :left,
        _m,
        :release,
        _cc
      ) do
    %{state | workspace: %{state.workspace | mouse: MouseState.stop_drag(state.workspace.mouse)}}
  end

  # ── Mouse motion (hover tracking) ──

  def handle(state, row, col, :none, _mods, :motion, _cc) do
    # Clear any existing hover popup when the mouse moves
    state =
      if state.hover_popup != nil do
        %{state | hover_popup: nil}
      else
        state
      end

    %{
      state
      | workspace: %{
          state.workspace
          | mouse: MouseState.set_hover(state.workspace.mouse, row, col)
        }
    }
  end

  # ── Ignore all other mouse events ──

  def handle(state, _row, _col, _button, _mods, _type, _cc), do: state

  # ── Left press dispatcher ──────────────────────────────────────────────────

  @spec handle_left_press(state(), integer(), integer(), non_neg_integer(), pos_integer()) ::
          state()
  defp handle_left_press(state, row, col, mods, native_click_count) do
    # Record press for multi-click detection
    mouse = MouseState.record_press(state.workspace.mouse, row, col, native_click_count)
    state = %{state | workspace: %{state.workspace | mouse: mouse}}
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
        buf = state.workspace.buffers.active

        case word_boundaries_at(buf, line, buf_col) do
          {word_start, word_end} ->
            BufferServer.move_to(buf, {line, word_end})

            visual_state = %VisualState{
              visual_anchor: {line, word_start},
              visual_type: :char
            }

            state = EditorState.transition_mode(state, :visual, visual_state)

            %{
              state
              | workspace: %{
                  state.workspace
                  | mouse: MouseState.start_drag(state.workspace.mouse, {line, word_start})
                }
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
        buf = state.workspace.buffers.active

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

        state = EditorState.transition_mode(state, :visual, visual_state)

        %{
          state
          | workspace: %{
              state.workspace
              | mouse: MouseState.start_drag(state.workspace.mouse, {line, 0})
            }
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
        buf = state.workspace.buffers.active

        # Get current cursor as anchor if not already in visual mode
        anchor =
          case Minga.Editor.Editing.mode(state) do
            :visual ->
              Minga.Editor.Editing.visual_anchor(state)

            _ ->
              BufferServer.cursor(buf)
          end

        BufferServer.move_to(buf, {target_line, target_col})

        visual_state = %VisualState{
          visual_anchor: anchor,
          visual_type: :char
        }

        EditorState.transition_mode(state, :visual, visual_state)
    end
  end

  # ── Cmd/Ctrl+click: go-to-definition ───────────────────────────────────────

  @spec handle_goto_definition_click(state(), integer(), integer()) :: state()
  defp handle_goto_definition_click(state, row, col) do
    case mouse_to_buffer_pos(state, row, col) do
      nil ->
        state

      {target_line, target_col} ->
        buf = state.workspace.buffers.active
        BufferServer.move_to(buf, {target_line, target_col})
        state = cancel_mode_for_mouse(state)
        state = EditorState.transition_mode(state, :normal)
        Minga.Editor.dispatch_command(state, :goto_definition)
    end
  end

  # ── Word-by-word drag snapping ─────────────────────────────────────────────

  @spec snap_selection_to_words(
          state(),
          {non_neg_integer(), non_neg_integer()}
        ) :: state()
  defp snap_selection_to_words(state, anchor) do
    buf = state.workspace.buffers.active
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
    buf = state.workspace.buffers.active
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

    EditorState.transition_mode(state, :visual, visual_state)
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
  defp maybe_start_separator_drag(%{workspace: %{windows: %{tree: nil}}} = state, _row, _col),
    do: state

  defp maybe_start_separator_drag(state, row, col) do
    screen = Layout.get(state).editor_area

    case WindowTree.separator_at(state.workspace.windows.tree, screen, row, col) do
      {:ok, {dir, sep_pos}} ->
        %{
          state
          | workspace: %{
              state.workspace
              | mouse: MouseState.start_resize(state.workspace.mouse, dir, sep_pos)
            }
        }

      :error ->
        state
    end
  end

  @spec maybe_handle_content_click(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp maybe_handle_content_click(
         %{workspace: %{mouse: %MouseState{resize_dragging: {_, _}}}} = state,
         _row,
         _col
       ),
       do: state

  defp maybe_handle_content_click(state, row, col) do
    case tab_bar_click(state, row, col) do
      {:command, cmd} -> dispatch_tab_bar_command(state, cmd)
      :not_tab_bar -> handle_content_click(state, row, col)
    end
  end

  @spec dispatch_tab_bar_command(state(), atom()) :: state()
  defp dispatch_tab_bar_command(state, cmd) do
    case Atom.to_string(cmd) do
      "tab_close_" <> _ -> close_tab_by_command(state, cmd)
      _ -> Minga.Editor.dispatch_command(state, cmd)
    end
  end

  @spec handle_separator_drag(state(), WindowTree.direction(), non_neg_integer(), integer()) ::
          state()
  defp handle_separator_drag(state, dir, sep_pos, new_pos) do
    screen = Layout.get(state).editor_area

    case WindowTree.resize_at(state.workspace.windows.tree, screen, dir, sep_pos, new_pos) do
      {:ok, new_tree} ->
        state = %{
          state
          | workspace: %{
              state.workspace
              | windows: %{state.workspace.windows | tree: new_tree},
                mouse: MouseState.update_resize(state.workspace.mouse, dir, new_pos)
            }
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
    # Check modeline click first
    case modeline_click(state, row, col) do
      {:command, cmd} ->
        Minga.Editor.dispatch_command(state, cmd)

      :not_modeline ->
        state = maybe_focus_window_at(state, row, col)

        case mouse_to_buffer_pos(state, row, col) do
          nil ->
            state

          {target_line, target_col} ->
            BufferServer.move_to(state.workspace.buffers.active, {target_line, target_col})

            state = cancel_mode_for_mouse(state)
            state = EditorState.transition_mode(state, :normal)

            %{
              state
              | workspace: %{
                  state.workspace
                  | mouse: MouseState.start_drag(state.workspace.mouse, {target_line, target_col})
                }
            }
        end
    end
  end

  @spec maybe_focus_window_at(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp maybe_focus_window_at(%{workspace: %{windows: %{tree: nil}}} = state, _row, _col),
    do: state

  defp maybe_focus_window_at(state, row, col) do
    screen = Layout.get(state).editor_area

    case WindowTree.window_at(state.workspace.windows.tree, screen, row, col) do
      {:ok, id, _rect} -> EditorState.focus_window(state, id)
      :error -> state
    end
  end

  @spec gutter_width(state(), non_neg_integer()) :: non_neg_integer()
  defp gutter_width(%{workspace: %{buffers: %{active: buf}}}, total_lines) do
    ln_style =
      if buf, do: BufferServer.get_option(buf, :line_numbers), else: :none

    number_w =
      if ln_style == :none, do: 0, else: Viewport.gutter_width(total_lines)

    # Sign column is always reserved for consistent gutter layout.
    Gutter.total_width(number_w)
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
  defp mouse_to_buffer_line(%{workspace: %{buffers: %{active: buf}}} = state, row) do
    layout = Layout.get(state)

    case Layout.active_window_layout(layout, state) do
      %{content: {win_row, _win_col, content_w, win_h}} ->
        window = EditorState.active_window_struct(state)
        total_lines = BufferServer.line_count(buf)
        {cursor_line, _} = BufferServer.cursor(buf)
        scroll_top = window_scroll_top(window, win_h, content_w, cursor_line, buf)
        local_row = row - win_row
        target_line = local_row + scroll_top

        if local_row < 0 or local_row >= win_h or target_line >= total_lines do
          nil
        else
          target_line
        end

      nil ->
        nil
    end
  end

  @spec mouse_to_buffer_pos_single(state(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp mouse_to_buffer_pos_single(%{workspace: %{buffers: %{active: buf}}} = state, row, col) do
    layout = Layout.get(state)

    case Layout.active_window_layout(layout, state) do
      %{content: {win_row, win_col, content_w, win_h}} ->
        window = EditorState.active_window_struct(state)
        total_lines = BufferServer.line_count(buf)
        gutter_w = gutter_width(state, total_lines)
        {cursor_line, _} = BufferServer.cursor(buf)
        scroll_top = window_scroll_top(window, win_h, content_w, cursor_line, buf)
        local_row = row - win_row
        local_col = max(col - win_col - gutter_w, 0) + scroll_left(state, buf)

        resolve_with_display_map(
          buf,
          window,
          local_row,
          local_col,
          scroll_top,
          win_h,
          content_w,
          total_lines
        )

      nil ->
        nil
    end
  end

  @spec mouse_to_buffer_pos_split(state(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp mouse_to_buffer_pos_split(state, row, col) do
    layout = Layout.get(state)

    case WindowTree.window_at(state.workspace.windows.tree, layout.editor_area, row, col) do
      {:ok, id, {win_row, win_col, _win_w, _win_h}} ->
        window = Map.fetch!(state.workspace.windows.map, id)
        win_layout = Map.fetch!(layout.window_layouts, id)
        {_cr, _cc, content_w, content_h} = win_layout.content
        buf = window.buffer
        total_lines = BufferServer.line_count(buf)
        gutter_w = gutter_width(state, total_lines)
        {cursor_line, _} = window.cursor
        scroll_top = window_scroll_top(window, content_h, content_w, cursor_line, buf)
        local_row = row - win_row
        local_col = max(col - win_col - gutter_w, 0)

        resolve_with_display_map(
          buf,
          window,
          local_row,
          local_col,
          scroll_top,
          content_h,
          content_w,
          total_lines
        )

      :error ->
        nil
    end
  end

  # Resolves a click position using the DisplayMap to correctly handle
  # block decorations, virtual lines, and folds. If the clicked display
  # row is a block decoration, dispatches on_click and returns nil.
  @spec resolve_with_display_map(
          pid(),
          Window.t() | nil,
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          non_neg_integer()
        ) :: {non_neg_integer(), non_neg_integer()} | nil
  defp resolve_with_display_map(
         buf,
         window,
         local_row,
         local_col,
         scroll_top,
         win_h,
         content_w,
         total_lines
       ) do
    decs = BufferServer.decorations(buf)
    fold_map = if window, do: window.fold_map, else: FoldMap.new()

    case DisplayMap.compute(fold_map, decs, scroll_top, win_h, total_lines, content_w) do
      nil ->
        # No display map needed, use direct line mapping
        target_line = local_row + scroll_top
        resolve_buffer_pos(buf, local_row, win_h, target_line, local_col, total_lines)

      %DisplayMap{} = dm ->
        # Look up what's at this display row
        case DisplayMap.buf_line_for_display_row(dm, local_row) do
          nil ->
            nil

          target_line ->
            entry = Enum.at(dm.entries, local_row)

            handle_display_row_click(
              entry,
              buf,
              local_row,
              local_col,
              win_h,
              target_line,
              total_lines
            )
        end
    end
  catch
    :exit, _ ->
      target_line = local_row + scroll_top
      resolve_buffer_pos(buf, local_row, win_h, target_line, local_col, total_lines)
  end

  defp handle_display_row_click(
         {_line, {:block, block, line_idx}},
         _buf,
         _row,
         col,
         _win_h,
         _target,
         _total
       ) do
    if block.on_click, do: block.on_click.(line_idx, col)
    nil
  end

  defp handle_display_row_click(
         {_line, {:virtual_line, _}},
         _buf,
         _row,
         _col,
         _win_h,
         _target,
         _total
       ) do
    nil
  end

  defp handle_display_row_click(
         _entry,
         buf,
         local_row,
         local_col,
         win_h,
         target_line,
         total_lines
       ) do
    resolve_buffer_pos(buf, local_row, win_h, target_line, local_col, total_lines)
  end

  defp resolve_buffer_pos(_buf, row, visible_rows, _line, _col, _total)
       when row >= visible_rows,
       do: nil

  defp resolve_buffer_pos(_buf, _row, _visible, target_line, _col, total)
       when target_line >= total,
       do: nil

  defp resolve_buffer_pos(_buf, _row, _visible, target_line, _col, _total)
       when target_line < 0,
       do: nil

  defp resolve_buffer_pos(buf, _row, _visible, target_line, target_col, _total) do
    # Adjust for inline virtual text: the target_col is a display column,
    # but if inline virtual text is present, the buffer column is different.
    adjusted_col = adjust_col_for_virtual_text(buf, target_line, target_col)
    {target_line, clamp_col_to_line(buf, target_line, adjusted_col)}
  end

  @spec auto_copy_selection(EditorState.t()) :: EditorState.t()
  defp auto_copy_selection(
         %{workspace: %{vim: %{mode: :visual, mode_state: ms}, buffers: %{active: buf}}} = state
       )
       when is_pid(buf) do
    text = selection_text(buf, ms)
    maybe_copy_to_clipboard(text)
    state
  catch
    :exit, _ -> state
  end

  defp auto_copy_selection(state), do: state

  @spec selection_text(pid(), map()) :: String.t() | nil
  defp selection_text(buf, %{visual_type: :char} = ms) do
    BufferServer.get_range(buf, ms.visual_anchor, BufferServer.cursor(buf))
  end

  defp selection_text(buf, %{visual_type: :line} = ms) do
    {a_line, _} = ms.visual_anchor
    {c_line, _} = BufferServer.cursor(buf)
    BufferServer.get_lines_content(buf, min(a_line, c_line), max(a_line, c_line))
  end

  defp maybe_copy_to_clipboard(text) when is_binary(text) and text != "" do
    case Options.get(:clipboard) do
      :none -> :ok
      _ -> Minga.Clipboard.write(text)
    end
  end

  defp maybe_copy_to_clipboard(_text), do: :ok

  @spec adjust_col_for_virtual_text(pid(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp adjust_col_for_virtual_text(buf, line, display_col) do
    Decorations.display_col_to_buf_col(BufferServer.decorations(buf), line, display_col)
  catch
    :exit, _ -> display_col
  end

  # Computes the scroll top the same way the render pipeline does:
  # Returns the viewport's scroll top. Now reads from the window's
  # persistent viewport instead of computing a throwaway one each time.
  @spec window_scroll_top(
          Window.t() | nil,
          pos_integer(),
          pos_integer(),
          non_neg_integer(),
          pid()
        ) ::
          non_neg_integer()
  defp window_scroll_top(%Window{viewport: vp}, _h, _w, _cursor, _buf), do: vp.top

  defp window_scroll_top(nil, content_height, content_width, cursor_line, buf) do
    # Fallback when no window struct is available
    vp = Viewport.new(content_height, content_width, 0)
    vp = Viewport.scroll_to_cursor(vp, {cursor_line, 0}, buf)
    vp.top
  end

  @spec scroll_left(state(), pid()) :: non_neg_integer()
  defp scroll_left(state, _buf), do: active_window_viewport(state).left

  # ── Viewport helpers ───────────────────────────────────────────────────────

  @spec scroll_viewport(Viewport.t(), integer(), non_neg_integer()) :: Viewport.t()
  defp scroll_viewport(%Viewport{} = vp, delta, total_lines) do
    visible_rows = Viewport.content_rows(vp)
    max_top = max(0, total_lines - visible_rows)
    new_top = (vp.top + delta) |> max(0) |> min(max_top)
    %Viewport{vp | top: new_top}
  end

  # Clamps the cursor to remain visible within the viewport, respecting
  # scroll_margin so the render pipeline's scroll_to_cursor doesn't override
  # the viewport position the mouse handler just set.
  #
  # Direction-aware (matches vim scrolloff behavior):
  # - Scrolling UP: enforce bottom margin (push cursor toward top)
  # - Scrolling DOWN: enforce top margin (push cursor toward bottom)
  @spec clamp_cursor_to_viewport(state(), :up | :down) :: state()
  defp clamp_cursor_to_viewport(%{workspace: %{buffers: %{active: buf}}} = state, direction) do
    vp = active_window_viewport(state)
    {cursor_line, cursor_col} = BufferServer.cursor(buf)
    {first_line, last_line} = Viewport.visible_range(vp)

    margin = scroll_margin()
    visible_rows = Viewport.content_rows(vp)
    effective_margin = min(margin, div(visible_rows - 1, 2))

    target_line =
      clamp_with_margin(cursor_line, first_line, last_line, effective_margin, direction)

    if target_line != cursor_line do
      BufferServer.move_to(buf, {target_line, clamp_col_to_line(buf, target_line, cursor_col)})
    end

    state
  end

  # First clamp to basic visible range, then apply margin for scroll direction.
  @spec clamp_with_margin(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          :up | :down
        ) :: non_neg_integer()
  defp clamp_with_margin(cursor, first, last, margin, direction) do
    # Basic visibility clamp
    clamped = cursor |> max(first) |> min(last)

    # Direction-aware margin clamp
    case direction do
      :up ->
        # Scrolling up: enforce bottom margin (push cursor toward top)
        max_cursor = last - margin
        min(clamped, max(max_cursor, first))

      :down ->
        # Scrolling down: enforce top margin (push cursor toward bottom)
        min_cursor = first + margin
        max(clamped, min(min_cursor, last))
    end
  end

  @spec scroll_margin() :: non_neg_integer()
  defp scroll_margin do
    Options.get(:scroll_margin)
  catch
    :exit, _ -> 5
  end

  @spec maybe_auto_scroll(state(), integer()) :: state()
  defp maybe_auto_scroll(%{workspace: %{buffers: %{active: buf}}} = state, row) when row <= 0 do
    vp = active_window_viewport(state)
    page_move(buf, vp, -1)
    state
  end

  defp maybe_auto_scroll(%{workspace: %{buffers: %{active: buf}}} = state, row) do
    vp = active_window_viewport(state)
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
        BufferServer.move_to(state.workspace.buffers.active, {line, c})
        state
    end
  end

  @spec enter_visual_if_needed(state(), {non_neg_integer(), non_neg_integer()}) :: state()
  defp enter_visual_if_needed(%{workspace: %{vim: %{mode: :visual}}} = state, _anchor), do: state

  defp enter_visual_if_needed(state, anchor) do
    visual_state = %VisualState{visual_anchor: anchor, visual_type: :char}
    EditorState.transition_mode(state, :visual, visual_state)
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
  defp cancel_mode_for_mouse(%{workspace: %{vim: %{mode: :command}}} = state) do
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

  # ── Tab bar close (middle-click) ─────────────────────────────────────────

  @spec close_tab_at(state(), non_neg_integer(), non_neg_integer()) :: state()
  defp close_tab_at(state, _row, col) do
    case find_tab_bar_region(state.tab_bar_click_regions, col) do
      {:command, cmd} -> close_tab_by_command(state, cmd)
      :not_tab_bar -> state
    end
  end

  @spec close_tab_by_command(state(), atom()) :: state()
  defp close_tab_by_command(state, cmd) do
    case parse_tab_id(cmd) do
      {:ok, tab_id} ->
        state = EditorState.switch_tab(state, tab_id)
        Minga.Editor.dispatch_command(state, :kill_buffer)

      :error ->
        state
    end
  end

  @spec parse_tab_id(atom()) :: {:ok, pos_integer()} | :error
  defp parse_tab_id(cmd) do
    case Atom.to_string(cmd) do
      "tab_goto_" <> id_str ->
        case Integer.parse(id_str) do
          {tab_id, ""} -> {:ok, tab_id}
          _ -> :error
        end

      "tab_close_" <> id_str ->
        case Integer.parse(id_str) do
          {tab_id, ""} -> {:ok, tab_id}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  # ── Tab bar click detection ──────────────────────────────────────────────

  @spec tab_bar_click(state(), non_neg_integer(), non_neg_integer()) ::
          {:command, atom()} | :not_tab_bar
  defp tab_bar_click(state, row, col) do
    layout = Layout.get(state)

    case layout.tab_bar do
      nil ->
        :not_tab_bar

      {tb_row, tb_col, tb_width, _tb_height} ->
        if row == tb_row and col >= tb_col and col < tb_col + tb_width do
          find_tab_bar_region(state.tab_bar_click_regions, col)
        else
          :not_tab_bar
        end
    end
  end

  @spec find_tab_bar_region(
          [Minga.Editor.TabBarRenderer.click_region()],
          non_neg_integer()
        ) :: {:command, atom()} | :not_tab_bar
  defp find_tab_bar_region(regions, col) do
    case Enum.find(regions, fn {start_col, end_col, _cmd} ->
           col >= start_col and col <= end_col
         end) do
      {_, _, cmd} -> {:command, cmd}
      nil -> :not_tab_bar
    end
  end

  # ── Modeline segment click detection ─────────────────────────────────────

  # Click regions are attached to modeline segments at render time (like
  # Doom Emacs local-map text properties). The mouse handler just does a
  # range lookup against the cached regions.
  @spec modeline_click(state(), non_neg_integer(), non_neg_integer()) ::
          {:command, atom()} | :not_modeline
  defp modeline_click(state, row, col) do
    layout = Layout.get(state)

    # Check if the click row is a modeline row in any window
    is_modeline =
      Enum.any?(layout.window_layouts, fn {_id, wl} ->
        {ml_row, ml_col, ml_width, ml_height} = wl.modeline
        ml_height > 0 and row == ml_row and col >= ml_col and col < ml_col + ml_width
      end)

    if is_modeline do
      find_click_region(state.modeline_click_regions, col)
    else
      :not_modeline
    end
  end

  # GUI frontends accumulate pixel deltas and emit one scroll event per
  # line height crossed, so each event = 1 line. TUI frontends send one
  # event per wheel tick, so each event = 3 lines for usable speed.
  @spec scroll_lines(state()) :: pos_integer()
  defp scroll_lines(%{capabilities: %Capabilities{frontend_type: :native_gui}}),
    do: @gui_scroll_lines

  defp scroll_lines(_state) do
    Options.get(:scroll_lines)
  catch
    :exit, _ -> 1
  end

  # Delegates to EditorState shared helpers.
  defp active_window_viewport(state), do: EditorState.active_window_viewport(state)

  defp put_active_window_viewport(state, new_vp),
    do: EditorState.put_active_window_viewport(state, new_vp)

  @spec find_click_region([Minga.Editor.Modeline.click_region()], non_neg_integer()) ::
          {:command, atom()} | :not_modeline
  defp find_click_region(regions, col) do
    case Enum.find(regions, fn {col_start, col_end, _cmd} ->
           col >= col_start and col < col_end
         end) do
      {_start, _end, command} -> {:command, command}
      nil -> :not_modeline
    end
  end
end
