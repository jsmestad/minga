defmodule Minga.Editor.Commands.Movement do
  @moduledoc """
  Cursor movement commands: h/j/k/l, word motions, find-char, bracket
  matching, paragraph jumps, page scroll, and screen-relative positioning.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Buffer.Unicode

  alias Minga.Editor.Commands.Helpers
  alias Minga.Editor.FoldMap
  alias Minga.Editor.Layout
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.Mode
  alias Minga.Motion.VisualLine

  @type state :: EditorState.t()

  @spec execute(state(), Mode.command()) :: state()

  # ── h / l (mode-aware) ────────────────────────────────────────────────────

  def execute(%{buffers: %{active: buf}, vim: %{mode: mode}} = state, :move_left) do
    if mode in [:insert, :replace] do
      BufferServer.move(buf, :left)
    else
      gb = BufferServer.snapshot(buf)
      {_line, col} = Document.cursor(gb)
      if col > 0, do: BufferServer.move(buf, :left)
    end

    state
  end

  def execute(%{buffers: %{active: buf}, vim: %{mode: mode}} = state, :move_right) do
    if mode in [:insert, :replace] do
      BufferServer.move(buf, :right)
    else
      gb = BufferServer.snapshot(buf)
      {line, col} = Document.cursor(gb)

      max_col =
        case Document.lines(gb, line, 1) do
          [text] when byte_size(text) > 0 -> Unicode.last_grapheme_byte_offset(text)
          _ -> 0
        end

      if col < max_col, do: BufferServer.move(buf, :right)
    end

    state
  end

  def execute(%{buffers: %{active: buf}} = state, :move_up) do
    if wrap_enabled?(buf) do
      visual_line_move(buf, state, :up)
    else
      BufferServer.move(buf, :up)
      skip_folded_line(state, buf, :up)
    end
  end

  def execute(%{buffers: %{active: buf}} = state, :move_down) do
    if wrap_enabled?(buf) do
      visual_line_move(buf, state, :down)
    else
      BufferServer.move(buf, :down)
      skip_folded_line(state, buf, :down)
    end
  end

  # Logical line movement (gj/gk). Always moves by logical lines regardless
  # of wrap setting.
  def execute(%{buffers: %{active: buf}} = state, :move_logical_down) do
    BufferServer.move(buf, :down)
    state
  end

  def execute(%{buffers: %{active: buf}} = state, :move_logical_up) do
    BufferServer.move(buf, :up)
    state
  end

  # ── Line start / end ──────────────────────────────────────────────────────

  def execute(%{buffers: %{active: buf}} = state, :move_to_line_start) do
    if wrap_enabled?(buf) do
      visual_line_edge(buf, state, :start)
    else
      logical_line_start(buf)
      state
    end
  end

  def execute(%{buffers: %{active: buf}} = state, :move_to_line_end) do
    if wrap_enabled?(buf) do
      visual_line_edge(buf, state, :end)
    else
      logical_line_end(buf)
      state
    end
  end

  # g0/g$ — logical line start/end (always logical, even with wrap on)
  def execute(%{buffers: %{active: buf}} = state, :move_to_logical_line_start) do
    logical_line_start(buf)
    state
  end

  def execute(%{buffers: %{active: buf}} = state, :move_to_logical_line_end) do
    logical_line_end(buf)
    state
  end

  # ── Word motions (small) ───────────────────────────────────────────────────

  def execute(%{buffers: %{active: buf}} = state, :word_forward) do
    Helpers.apply_motion(buf, &Minga.Motion.word_forward/2)
    state
  end

  def execute(%{buffers: %{active: buf}} = state, :word_backward) do
    Helpers.apply_motion(buf, &Minga.Motion.word_backward/2)
    state
  end

  def execute(%{buffers: %{active: buf}} = state, :word_end) do
    Helpers.apply_motion(buf, &Minga.Motion.word_end/2)
    state
  end

  # ── Word motions (WORD / big) ─────────────────────────────────────────────

  def execute(%{buffers: %{active: buf}} = state, :word_forward_big) do
    Helpers.apply_motion(buf, &Minga.Motion.word_forward_big/2)
    state
  end

  def execute(%{buffers: %{active: buf}} = state, :word_backward_big) do
    Helpers.apply_motion(buf, &Minga.Motion.word_backward_big/2)
    state
  end

  def execute(%{buffers: %{active: buf}} = state, :word_end_big) do
    Helpers.apply_motion(buf, &Minga.Motion.word_end_big/2)
    state
  end

  # ── Line / document navigation ─────────────────────────────────────────────

  def execute(%{buffers: %{active: buf}} = state, :move_to_first_non_blank) do
    Helpers.apply_motion(buf, &Minga.Motion.first_non_blank/2)
    state
  end

  def execute(%{buffers: %{active: buf}} = state, :move_to_document_start) do
    gb = BufferServer.snapshot(buf)
    new_pos = Minga.Motion.document_start(gb)
    BufferServer.move_to(buf, new_pos)
    state
  end

  def execute(%{buffers: %{active: buf}} = state, :move_to_document_end) do
    gb = BufferServer.snapshot(buf)
    new_pos = Minga.Motion.document_end(gb)
    BufferServer.move_to(buf, new_pos)
    state
  end

  def execute(%{buffers: %{active: buf}} = state, {:goto_line, line_num}) do
    target_line = max(0, line_num - 1)
    BufferServer.move_to(buf, {target_line, 0})
    state
  end

  def execute(%{buffers: %{active: buf}} = state, :next_line_first_non_blank) do
    gb = BufferServer.snapshot(buf)
    {line, _col} = Document.cursor(gb)
    total = Document.line_count(gb)
    next_line = min(line + 1, total - 1)
    new_pos = Minga.Motion.first_non_blank(gb, {next_line, 0})
    BufferServer.move_to(buf, new_pos)
    state
  end

  def execute(%{buffers: %{active: buf}} = state, :prev_line_first_non_blank) do
    gb = BufferServer.snapshot(buf)
    {line, _col} = Document.cursor(gb)
    prev_line = max(line - 1, 0)
    new_pos = Minga.Motion.first_non_blank(gb, {prev_line, 0})
    BufferServer.move_to(buf, new_pos)
    state
  end

  # ── Find-char motions ─────────────────────────────────────────────────────

  def execute(%{buffers: %{active: buf}} = state, {:find_char, dir, char}) do
    Helpers.apply_find_char(buf, dir, char)
    %{state | vim: %{state.vim | last_find_char: {dir, char}}}
  end

  def execute(
        %{vim: %{last_find_char: {dir, char}}, buf: %{buffer: buf}} = state,
        :repeat_find_char
      ) do
    Helpers.apply_find_char(buf, dir, char)
    state
  end

  def execute(state, :repeat_find_char), do: state

  def execute(
        %{vim: %{last_find_char: {dir, char}}, buf: %{buffer: buf}} = state,
        :repeat_find_char_reverse
      ) do
    reverse_dir = Helpers.reverse_find_direction(dir)
    Helpers.apply_find_char(buf, reverse_dir, char)
    state
  end

  def execute(state, :repeat_find_char_reverse), do: state

  # ── Bracket matching ──────────────────────────────────────────────────────

  def execute(%{buffers: %{active: buf}} = state, :match_bracket) do
    Helpers.apply_motion(buf, &Minga.Motion.match_bracket/2)
    state
  end

  # ── Paragraph motions ─────────────────────────────────────────────────────

  def execute(%{buffers: %{active: buf}} = state, :paragraph_forward) do
    Helpers.apply_motion(buf, &Minga.Motion.paragraph_forward/2)
    state
  end

  def execute(%{buffers: %{active: buf}} = state, :paragraph_backward) do
    Helpers.apply_motion(buf, &Minga.Motion.paragraph_backward/2)
    state
  end

  # ── Screen-relative motions ───────────────────────────────────────────────

  def execute(%{buffers: %{active: buf}, viewport: vp} = state, {:move_to_screen, position}) do
    {first_line, _last_line} = Viewport.visible_range(vp)
    visible_rows = Viewport.content_rows(vp)
    gb = BufferServer.snapshot(buf)
    total_lines = Document.line_count(gb)

    target_line =
      case position do
        :top -> first_line
        :middle -> min(first_line + div(visible_rows, 2), total_lines - 1)
        :bottom -> min(first_line + visible_rows - 1, total_lines - 1)
      end

    BufferServer.move_to(buf, {target_line, 0})
    state
  end

  # ── Page scrolling ────────────────────────────────────────────────────────

  def execute(%{buffers: %{active: buf}, viewport: vp} = state, :half_page_down) do
    Helpers.page_move(buf, vp, div(Viewport.content_rows(vp), 2))
    state
  end

  def execute(%{buffers: %{active: buf}, viewport: vp} = state, :half_page_up) do
    Helpers.page_move(buf, vp, -div(Viewport.content_rows(vp), 2))
    state
  end

  def execute(%{buffers: %{active: buf}, viewport: vp} = state, :page_down) do
    Helpers.page_move(buf, vp, Viewport.content_rows(vp))
    state
  end

  def execute(%{buffers: %{active: buf}, viewport: vp} = state, :page_up) do
    Helpers.page_move(buf, vp, -Viewport.content_rows(vp))
    state
  end

  # ── Window commands ────────────────────────────────────────────────────────

  def execute(state, :window_left), do: navigate_window(state, :left)
  def execute(state, :window_right), do: navigate_window(state, :right)
  def execute(state, :window_up), do: navigate_window(state, :up)
  def execute(state, :window_down), do: navigate_window(state, :down)

  def execute(state, :split_vertical), do: split_window(state, :vertical)
  def execute(state, :split_horizontal), do: split_window(state, :horizontal)

  def execute(state, :window_close), do: close_window(state)

  def execute(state, :describe_key) do
    new_mode_state = %{state.vim.mode_state | pending_describe_key: true}

    %{
      state
      | vim: %{state.vim | mode_state: new_mode_state},
        status_msg: "Press key to describe:"
    }
  end

  @spec split_window(state(), WindowTree.direction()) :: state()
  defp split_window(%{windows: %{tree: nil}} = state, _direction), do: state

  defp split_window(state, direction) do
    ws = state.windows
    active_id = ws.active
    new_id = ws.next_id

    case WindowTree.split(ws.tree, active_id, direction, new_id) do
      {:ok, new_tree} -> apply_split(state, new_tree, active_id, new_id)
      :error -> state
    end
  end

  @spec apply_split(state(), WindowTree.t(), Window.id(), Window.id()) :: state()
  defp apply_split(state, new_tree, active_id, new_id) do
    active_window = Map.fetch!(state.windows.map, active_id)
    cursor = BufferServer.cursor(active_window.buffer)

    # New window gets a copy of the current cursor position
    new_window = Window.new(new_id, active_window.buffer, 24, 80, cursor)

    # Also snapshot the current cursor into the active window
    state = EditorState.update_window(state, active_id, &%{&1 | cursor: cursor})

    ws = state.windows

    state = %{
      state
      | windows: %{
          ws
          | tree: new_tree,
            map: Map.put(ws.map, new_id, new_window),
            next_id: new_id + 1
        }
    }

    resize_windows_to_layout(state)
  end

  @spec resize_windows_to_layout(state()) :: state()
  defp resize_windows_to_layout(state) do
    # Force layout recompute: the window tree just changed (split/close)
    # and any cached layout is stale.
    state = Layout.put(state)
    layout = Layout.get(state)

    Enum.reduce(layout.window_layouts, state, fn {id, wl}, acc ->
      {_r, _c, width, height} = wl.total
      EditorState.update_window(acc, id, &Window.resize(&1, height, width))
    end)
  end

  @spec navigate_window(state(), WindowTree.nav_direction()) :: state()
  defp navigate_window(%{windows: %{tree: nil}} = state, _direction), do: state

  # When file tree is focused, navigating right unfocuses the tree
  defp navigate_window(%{file_tree: %{focused: true}} = state, :right) do
    state = put_in(state.file_tree.focused, false)
    %{state | keymap_scope: :editor}
  end

  defp navigate_window(state, direction) do
    screen = Layout.get(state).editor_area

    case WindowTree.focus_neighbor(state.windows.tree, state.windows.active, direction, screen) do
      {:ok, neighbor_id} ->
        EditorState.focus_window(state, neighbor_id)

      :error ->
        # No neighbor in that direction; check if the file tree is there
        maybe_focus_file_tree(state, direction)
    end
  end

  @spec maybe_focus_file_tree(state(), :left | :right | :up | :down) :: state()
  defp maybe_focus_file_tree(%{file_tree: %{tree: %Minga.FileTree{}}} = state, :left) do
    state = put_in(state.file_tree.focused, true)
    %{state | keymap_scope: :file_tree}
  end

  defp maybe_focus_file_tree(state, _direction), do: state

  @spec close_window(state()) :: state()
  defp close_window(%{windows: %{tree: nil}} = state), do: state

  defp close_window(state) do
    ws = state.windows

    case WindowTree.close(ws.tree, ws.active) do
      {:ok, new_tree} ->
        old_id = ws.active
        remaining = WindowTree.leaves(new_tree)
        new_active = hd(remaining)
        new_active_window = Map.fetch!(ws.map, new_active)

        # Restore the surviving window's cursor into the buffer
        BufferServer.move_to(new_active_window.buffer, new_active_window.cursor)

        %{
          state
          | windows: %{ws | tree: new_tree, map: Map.delete(ws.map, old_id), active: new_active},
            buffers: %{state.buffers | active: new_active_window.buffer}
        }

      :error ->
        %{state | status_msg: "Cannot close the last window"}
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  @spec visual_line_move(GenServer.server(), state(), :up | :down) :: state()
  defp visual_line_move(buf, state, direction) do
    doc = BufferServer.snapshot(buf)
    pos = Document.cursor(doc)
    content_w = content_width(state)

    new_pos =
      case direction do
        :down -> VisualLine.visual_down(doc, pos, content_w)
        :up -> VisualLine.visual_up(doc, pos, content_w)
      end

    BufferServer.move_to(buf, new_pos)
    state
  end

  @spec visual_line_edge(GenServer.server(), state(), :start | :end) :: state()
  defp visual_line_edge(buf, state, edge) do
    doc = BufferServer.snapshot(buf)
    pos = Document.cursor(doc)
    content_w = content_width(state)

    new_pos =
      case edge do
        :start -> VisualLine.visual_line_start(doc, pos, content_w)
        :end -> VisualLine.visual_line_end(doc, pos, content_w)
      end

    BufferServer.move_to(buf, new_pos)
    state
  end

  @spec logical_line_start(GenServer.server()) :: :ok
  defp logical_line_start(buf) do
    gb = BufferServer.snapshot(buf)
    {line, _col} = Document.cursor(gb)
    BufferServer.move_to(buf, {line, 0})
  end

  @spec logical_line_end(GenServer.server()) :: :ok
  defp logical_line_end(buf) do
    gb = BufferServer.snapshot(buf)
    {line, _col} = Document.cursor(gb)

    end_col =
      case Document.lines(gb, line, 1) do
        [text] when byte_size(text) > 0 -> Unicode.last_grapheme_byte_offset(text)
        _ -> 0
      end

    BufferServer.move_to(buf, {line, end_col})
  end

  @spec content_width(state()) :: pos_integer()
  defp content_width(state) do
    vp = Viewport.new(state.viewport.rows, state.viewport.cols)
    line_count = BufferServer.line_count(state.buffers.active)
    Viewport.content_cols(vp, line_count)
  end

  @spec wrap_enabled?(pid()) :: boolean()
  defp wrap_enabled?(buf) do
    BufferServer.get_option(buf, :wrap)
  catch
    :exit, _ -> false
  end

  # After a buffer move, check if the cursor landed on a folded (hidden) line.
  # If so, move it to the next/prev visible line using the active window's fold map.
  @spec skip_folded_line(state(), pid(), :up | :down) :: state()
  defp skip_folded_line(state, buf, direction) do
    case active_fold_map(state) do
      nil -> state
      fm -> maybe_skip_fold(fm, buf, direction, state)
    end
  end

  @spec active_fold_map(state()) :: FoldMap.t() | nil
  defp active_fold_map(state) do
    case EditorState.active_window_struct(state) do
      nil -> nil
      %Window{fold_map: fm} -> if FoldMap.empty?(fm), do: nil, else: fm
    end
  end

  @spec maybe_skip_fold(FoldMap.t(), pid(), :up | :down, state()) :: state()
  defp maybe_skip_fold(fm, buf, direction, state) do
    {cursor_line, _col} = BufferServer.cursor(buf)

    if FoldMap.folded?(fm, cursor_line) do
      target = fold_skip_target(fm, cursor_line, direction)
      BufferServer.move_to(buf, {target, 0})
    end

    state
  end

  @spec fold_skip_target(FoldMap.t(), non_neg_integer(), :up | :down) :: non_neg_integer()
  defp fold_skip_target(fm, cursor_line, :down), do: FoldMap.next_visible(fm, cursor_line - 1)
  defp fold_skip_target(fm, cursor_line, :up), do: FoldMap.prev_visible(fm, cursor_line + 1)
end
