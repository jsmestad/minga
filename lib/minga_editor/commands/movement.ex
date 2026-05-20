defmodule MingaEditor.Commands.Movement do
  @moduledoc """
  Cursor movement commands: h/j/k/l, word motions, find-char, bracket
  matching, paragraph jumps, page scroll, and screen-relative positioning.
  """

  use MingaEditor.Commands.Provider

  alias Minga.Buffer
  alias Minga.Buffer.Document
  alias Minga.Core.Unicode
  alias Minga.Core.WrapMap
  alias Minga.Parser.Manager, as: ParserManager
  alias Minga.Parser.StructuralNavResult

  alias MingaEditor.DisplayMap
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.Commands.Helpers
  alias MingaEditor.FoldMap
  alias MingaEditor.Layout
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Windows
  alias MingaEditor.VimState
  alias MingaEditor.Viewport
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias Minga.Mode

  @type state :: EditorState.t()
  @type structural_nav_action :: :parent | :first_child | :next_sibling | :prev_sibling

  @command_specs [
    {:move_left, "Move cursor left", true},
    {:move_right, "Move cursor right", true},
    {:move_up, "Move cursor up", true},
    {:move_down, "Move cursor down", true},
    {:move_logical_up, "Move cursor up (logical line)", true},
    {:move_logical_down, "Move cursor down (logical line)", true},
    {:move_to_logical_line_start, "Move to logical line start", true},
    {:move_to_logical_line_end, "Move to logical line end", true},
    {:move_to_line_start, "Move to line start", true},
    {:move_to_line_end, "Move to line end", true},
    {:word_forward, "Move to next word", true},
    {:word_backward, "Move to previous word", true},
    {:word_end, "Move to end of word", true},
    {:word_forward_big, "Move to next WORD", true},
    {:word_backward_big, "Move to previous WORD", true},
    {:word_end_big, "Move to end of WORD", true},
    {:move_to_first_non_blank, "Move to first non-blank character", true},
    {:move_to_document_start, "Move to document start", true},
    {:move_to_document_end, "Move to document end", true},
    {:next_line_first_non_blank, "Move to next line's first non-blank", true},
    {:prev_line_first_non_blank, "Move to previous line's first non-blank", true},
    {:repeat_find_char, "Repeat last find-char", true},
    {:repeat_find_char_reverse, "Repeat last find-char (reverse)", true},
    {:match_bracket, "Jump to matching bracket", true},
    {:nav_parent, "Move to parent AST node", true},
    {:nav_first_child, "Move to first child AST node", true},
    {:nav_next_sibling, "Move to next sibling AST node", true},
    {:nav_prev_sibling, "Move to previous sibling AST node", true},
    {:paragraph_forward, "Move to next paragraph", true},
    {:paragraph_backward, "Move to previous paragraph", true},
    {:half_page_down, "Scroll half page down", true},
    {:half_page_up, "Scroll half page up", true},
    {:page_down, "Scroll page down", true},
    {:page_up, "Scroll page up", true},
    {:scroll_down_line, "Scroll viewport down one line", true},
    {:scroll_up_line, "Scroll viewport up one line", true},
    {:scroll_center, "Center viewport on cursor (zz)", true},
    {:scroll_cursor_top, "Scroll cursor to top of viewport (zt)", true},
    {:scroll_cursor_bottom, "Scroll cursor to bottom of viewport (zb)", true},
    {:window_left, "Focus window left", true},
    {:window_right, "Focus window right", true},
    {:window_up, "Focus window up", true},
    {:window_down, "Focus window down", true},
    {:split_vertical, "Split window vertically", true},
    {:split_horizontal, "Split window horizontally", true},
    {:window_close, "Close window", true},
    {:describe_key, "Describe key binding", true}
  ]

  @spec execute(state(), Mode.command()) :: state()

  # ── h / l (mode-aware) ────────────────────────────────────────────────────

  def execute(
        %{workspace: %{buffers: %{active: buf}, editing: %{mode: mode}}} = state,
        :move_left
      ) do
    if mode in [:insert, :replace] do
      Buffer.move(buf, :left)
    else
      Buffer.move_if_possible(buf, :left)
    end

    state
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}, editing: %{mode: mode}}} = state,
        :move_right
      ) do
    if mode in [:insert, :replace] do
      Buffer.move(buf, :right)
    else
      Buffer.move_if_possible(buf, :right)
    end

    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :move_up) do
    if effective_wrap_enabled?(state, buf) do
      visual_line_move(buf, state, :up)
    else
      Buffer.move(buf, :up)
      skip_folded_line(state, buf, :up)
    end
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :move_down) do
    if effective_wrap_enabled?(state, buf) do
      visual_line_move(buf, state, :down)
    else
      Buffer.move(buf, :down)
      skip_folded_line(state, buf, :down)
    end
  end

  # Logical line movement (gj/gk). Always moves by logical lines regardless
  # of wrap setting.
  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :move_logical_down) do
    Buffer.move(buf, :down)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :move_logical_up) do
    Buffer.move(buf, :up)
    state
  end

  # ── Line start / end ──────────────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :move_to_line_start) do
    if effective_wrap_enabled?(state, buf) do
      visual_line_edge(buf, state, :start)
    else
      logical_line_start(buf)
      state
    end
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :move_to_line_end) do
    if effective_wrap_enabled?(state, buf) do
      visual_line_edge(buf, state, :end)
    else
      logical_line_end(buf)
      state
    end
  end

  # g0/g$ — logical line start/end (always logical, even with wrap on)
  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :move_to_logical_line_start) do
    logical_line_start(buf)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :move_to_logical_line_end) do
    logical_line_end(buf)
    state
  end

  # ── Word motions (small) ───────────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :word_forward) do
    Helpers.apply_motion(buf, &Minga.Editing.word_forward/2)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :word_backward) do
    Helpers.apply_motion(buf, &Minga.Editing.word_backward/2)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :word_end) do
    Helpers.apply_motion(buf, &Minga.Editing.word_end/2)
    state
  end

  # ── Word motions (WORD / big) ─────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :word_forward_big) do
    Helpers.apply_motion(buf, &Minga.Editing.word_forward_big/2)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :word_backward_big) do
    Helpers.apply_motion(buf, &Minga.Editing.word_backward_big/2)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :word_end_big) do
    Helpers.apply_motion(buf, &Minga.Editing.word_end_big/2)
    state
  end

  # ── Line / document navigation ─────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :move_to_first_non_blank) do
    Helpers.apply_motion(buf, &Minga.Editing.first_non_blank/2)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :move_to_document_start) do
    gb = Buffer.snapshot(buf)
    new_pos = Minga.Editing.document_start(gb)
    Buffer.move_to(buf, new_pos)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :move_to_document_end) do
    gb = Buffer.snapshot(buf)
    new_pos = Minga.Editing.document_end(gb)
    Buffer.move_to(buf, new_pos)
    maybe_repin_agent_chat(state)
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:goto_line, line_num}) do
    target_line = max(0, line_num - 1)
    Buffer.move_to(buf, {target_line, 0})
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :next_line_first_non_blank) do
    gb = Buffer.snapshot(buf)
    {line, _col} = Document.cursor(gb)
    total = Document.line_count(gb)
    next_line = min(line + 1, total - 1)
    new_pos = Minga.Editing.first_non_blank(gb, {next_line, 0})
    Buffer.move_to(buf, new_pos)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :prev_line_first_non_blank) do
    gb = Buffer.snapshot(buf)
    {line, _col} = Document.cursor(gb)
    prev_line = max(line - 1, 0)
    new_pos = Minga.Editing.first_non_blank(gb, {prev_line, 0})
    Buffer.move_to(buf, new_pos)
    state
  end

  # ── Find-char motions ─────────────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:find_char, dir, char}) do
    Helpers.apply_find_char(buf, dir, char)

    EditorState.update_workspace(state, fn ws ->
      SessionState.update_editing(ws, &VimState.set_last_find_char(&1, {dir, char}))
    end)
  end

  def execute(
        %{workspace: %{editing: %{last_find_char: {dir, char}}, buffers: %{active: buf}}} = state,
        :repeat_find_char
      ) do
    Helpers.apply_find_char(buf, dir, char)
    state
  end

  def execute(state, :repeat_find_char), do: state

  def execute(
        %{workspace: %{editing: %{last_find_char: {dir, char}}, buffers: %{active: buf}}} = state,
        :repeat_find_char_reverse
      ) do
    reverse_dir = Helpers.reverse_find_direction(dir)
    Helpers.apply_find_char(buf, reverse_dir, char)
    state
  end

  def execute(state, :repeat_find_char_reverse), do: state

  # ── Bracket matching ──────────────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :match_bracket) do
    state = Helpers.setup_for_motion(state, :match_bracket)
    buffer_id = Helpers.buffer_id_for_motion(state, buf, :match_bracket)

    Helpers.apply_motion(buf, fn gb, cursor ->
      Helpers.resolve_motion(gb, cursor, :match_bracket, buffer_id)
    end)

    state
  end

  # ── Structural AST navigation ─────────────────────────────────────────────

  def execute(state, :nav_parent), do: structural_nav(state, :parent)
  def execute(state, :nav_first_child), do: structural_nav(state, :first_child)
  def execute(state, :nav_next_sibling), do: structural_nav(state, :next_sibling)
  def execute(state, :nav_prev_sibling), do: structural_nav(state, :prev_sibling)

  # ── Paragraph motions ─────────────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :paragraph_forward) do
    Helpers.apply_motion(buf, &Minga.Editing.paragraph_forward/2)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :paragraph_backward) do
    Helpers.apply_motion(buf, &Minga.Editing.paragraph_backward/2)
    state
  end

  # ── Screen-relative motions ───────────────────────────────────────────────

  def execute(
        %{workspace: %{buffers: %{active: buf}, viewport: vp}} = state,
        {:move_to_screen, position}
      ) do
    {first_line, _last_line} = Viewport.visible_range(vp)
    visible_rows = Viewport.content_rows(vp)
    gb = Buffer.snapshot(buf)
    total_lines = Document.line_count(gb)

    target_line =
      case position do
        :top -> first_line
        :middle -> min(first_line + div(visible_rows, 2), total_lines - 1)
        :bottom -> min(first_line + visible_rows - 1, total_lines - 1)
      end

    Buffer.move_to(buf, {target_line, 0})
    state
  end

  # ── Page scrolling ────────────────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :half_page_down) do
    vp = active_viewport(state)
    delta = decoration_aware_page_delta(buf, vp, div(Viewport.content_rows(vp), 2))
    Helpers.page_move(buf, vp, delta)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :half_page_up) do
    vp = active_viewport(state)
    delta = decoration_aware_page_delta(buf, vp, div(Viewport.content_rows(vp), 2))
    Helpers.page_move(buf, vp, -delta)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :page_down) do
    vp = active_viewport(state)
    delta = decoration_aware_page_delta(buf, vp, Viewport.content_rows(vp))
    Helpers.page_move(buf, vp, delta)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :page_up) do
    vp = active_viewport(state)
    delta = decoration_aware_page_delta(buf, vp, Viewport.content_rows(vp))
    Helpers.page_move(buf, vp, -delta)
    state
  end

  # ── Scroll-without-cursor commands ─────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :scroll_down_line) do
    vp = active_viewport(state)
    {cursor_line, cursor_col} = Buffer.cursor(buf)
    total_lines = Buffer.line_count(buf)

    {new_vp, new_cursor} =
      if effective_wrap_enabled?(state, buf) do
        wrapped_scroll_down_line(state, buf, vp, {cursor_line, cursor_col}, total_lines)
      else
        {viewport, new_cursor_line} = Viewport.scroll_line_down(vp, cursor_line, total_lines)
        {viewport, {new_cursor_line, cursor_col}}
      end

    if new_cursor != {cursor_line, cursor_col} do
      Buffer.move_to(buf, new_cursor)
    end

    put_active_viewport(state, new_vp)
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :scroll_up_line) do
    vp = active_viewport(state)
    {cursor_line, cursor_col} = Buffer.cursor(buf)
    total_lines = Buffer.line_count(buf)

    {new_vp, new_cursor} =
      if effective_wrap_enabled?(state, buf) do
        wrapped_scroll_up_line(state, buf, vp, {cursor_line, cursor_col}, total_lines)
      else
        {viewport, new_cursor_line} = Viewport.scroll_line_up(vp, cursor_line, total_lines)
        {viewport, {new_cursor_line, cursor_col}}
      end

    if new_cursor != {cursor_line, cursor_col} do
      Buffer.move_to(buf, new_cursor)
    end

    put_active_viewport(state, new_vp)
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :scroll_center) do
    vp = active_viewport(state)
    {cursor_line, cursor_col} = Buffer.cursor(buf)
    total_lines = Buffer.line_count(buf)

    new_vp =
      if effective_wrap_enabled?(state, buf) do
        center_wrapped_viewport(
          buf,
          vp,
          cursor_line,
          cursor_col,
          content_width(state),
          total_lines,
          :center,
          width_oracle(state)
        )
      else
        Viewport.center_on(vp, cursor_line, total_lines)
      end

    put_active_viewport(state, new_vp)
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :scroll_cursor_top) do
    vp = active_viewport(state)
    {cursor_line, cursor_col} = Buffer.cursor(buf)
    total_lines = Buffer.line_count(buf)
    margin = scroll_margin(buf)

    new_vp =
      if effective_wrap_enabled?(state, buf) do
        center_wrapped_viewport(
          buf,
          vp,
          cursor_line,
          cursor_col,
          content_width(state),
          total_lines,
          :top,
          width_oracle(state)
        )
      else
        Viewport.top_on(vp, cursor_line, total_lines, margin)
      end

    put_active_viewport(state, new_vp)
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :scroll_cursor_bottom) do
    vp = active_viewport(state)
    {cursor_line, cursor_col} = Buffer.cursor(buf)
    total_lines = Buffer.line_count(buf)
    margin = scroll_margin(buf)

    new_vp =
      if effective_wrap_enabled?(state, buf) do
        center_wrapped_viewport(
          buf,
          vp,
          cursor_line,
          cursor_col,
          content_width(state),
          total_lines,
          :bottom,
          width_oracle(state)
        )
      else
        Viewport.bottom_on(vp, cursor_line, total_lines, margin)
      end

    put_active_viewport(state, new_vp)
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
    state =
      MingaEditor.Editing.update_mode_state(state, fn ms ->
        %{ms | describe_key: %Minga.Mode.DescribeKey{}}
      end)

    EditorState.set_status(state, "Press key to describe:")
  end

  @spec split_window(state(), WindowTree.direction()) :: state()
  defp split_window(%{workspace: %{windows: %{tree: nil}}} = state, _direction), do: state

  defp split_window(state, direction) do
    ws = state.workspace.windows
    active_id = ws.active
    {new_id, ws} = Windows.allocate_id(ws)

    case WindowTree.split(ws.tree, active_id, direction, new_id) do
      {:ok, new_tree} -> apply_split(state, ws, new_tree, active_id, new_id)
      :error -> state
    end
  end

  @spec apply_split(state(), Windows.t(), WindowTree.t(), Window.id(), Window.id()) :: state()
  defp apply_split(state, ws, new_tree, active_id, new_id) do
    case Windows.fetch(ws, active_id) do
      {:ok, active_window} ->
        cursor = Buffer.cursor(active_window.buffer)

        # New window gets a copy of the current cursor position
        new_window = Window.new(new_id, active_window.buffer, 24, 80, cursor)

        # Also snapshot the current cursor into the active window
        new_windows =
          ws
          |> Windows.update(active_id, &%{&1 | cursor: cursor})
          |> Windows.set_tree(new_tree)
          |> Windows.add_window(new_window)

        state = EditorState.update_workspace(state, &SessionState.set_windows(&1, new_windows))

        resize_windows_to_layout(state)

      :error ->
        state
    end
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
  defp navigate_window(%{workspace: %{windows: %{tree: nil}}} = state, _direction), do: state

  # When file tree is focused, navigating right unfocuses the tree
  # and restores the scope based on the active window's content type.
  defp navigate_window(%{workspace: %{file_tree: %{focused: true}}} = state, :right) do
    state = update_file_tree(state, &FileTreeState.unfocus/1)
    scope = EditorState.scope_for_active_window(state)
    EditorState.update_workspace(state, &SessionState.set_keymap_scope(&1, scope))
  end

  defp navigate_window(state, direction) do
    screen = Layout.get(state).editor_area

    case WindowTree.focus_neighbor(
           state.workspace.windows.tree,
           state.workspace.windows.active,
           direction,
           screen
         ) do
      {:ok, neighbor_id} ->
        EditorState.focus_window(state, neighbor_id)

      :error ->
        # No neighbor in that direction; check if the file tree is there
        maybe_focus_file_tree(state, direction)
    end
  end

  @spec maybe_focus_file_tree(state(), :left | :right | :up | :down) :: state()
  defp maybe_focus_file_tree(
         %{workspace: %{file_tree: %{tree: %Minga.Project.FileTree{}}}} = state,
         :left
       ) do
    state = update_file_tree(state, &FileTreeState.focus/1)
    EditorState.update_workspace(state, &SessionState.set_keymap_scope(&1, :file_tree))
  end

  defp maybe_focus_file_tree(state, _direction), do: state

  @spec close_window(state()) :: state()
  defp close_window(%{workspace: %{windows: %{tree: nil}}} = state), do: state

  defp close_window(state) do
    ws = state.workspace.windows

    case Windows.remove_window(ws, ws.active) do
      {:ok, removed_windows} ->
        focus_remaining_window(state, removed_windows)

      :error ->
        EditorState.set_status(state, "Cannot close the last window")
    end
  end

  @spec focus_remaining_window(state(), Windows.t()) :: state()
  defp focus_remaining_window(state, removed_windows) do
    remaining = WindowTree.leaves(removed_windows.tree)
    new_active = hd(remaining)

    case Windows.fetch(removed_windows, new_active) do
      {:ok, new_active_window} ->
        apply_remaining_window_focus(state, removed_windows, new_active, new_active_window)

      :error ->
        state
    end
  end

  @spec apply_remaining_window_focus(state(), Windows.t(), Window.id(), Window.t()) :: state()
  defp apply_remaining_window_focus(state, removed_windows, new_active, new_active_window) do
    # Restore the surviving window's cursor into the buffer
    Buffer.move_to(new_active_window.buffer, new_active_window.cursor)

    new_windows = Windows.set_active(removed_windows, new_active)
    new_buffers = Buffers.set_active_override(state.workspace.buffers, new_active_window.buffer)

    EditorState.update_workspace(state, fn workspace ->
      workspace
      |> SessionState.set_windows(new_windows)
      |> SessionState.set_buffers(new_buffers)
    end)
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  @spec structural_nav(state(), structural_nav_action()) :: state()
  defp structural_nav(%{workspace: %{buffers: %{active: buf}}} = state, action)
       when is_pid(buf) do
    command = structural_nav_command(action)
    state = Helpers.setup_for_motion(state, command)
    buffer_id = Helpers.buffer_id_for_motion(state, buf, command)
    {row, col} = Buffer.cursor(buf)

    case ParserManager.request_structural_nav(
           buffer_id,
           row,
           col,
           structural_nav_action_code(action)
         ) do
      %StructuralNavResult{type_name: type_name} = result ->
        Buffer.move_to(buf, StructuralNavResult.start_position(result))
        EditorState.set_status(state, "→ #{type_name}")

      nil ->
        state
    end
  end

  defp structural_nav(state, _action), do: state

  @spec structural_nav_command(structural_nav_action()) :: atom()
  defp structural_nav_command(:parent), do: :nav_parent
  defp structural_nav_command(:first_child), do: :nav_first_child
  defp structural_nav_command(:next_sibling), do: :nav_next_sibling
  defp structural_nav_command(:prev_sibling), do: :nav_prev_sibling

  @spec structural_nav_action_code(structural_nav_action()) :: 0..3
  defp structural_nav_action_code(:parent), do: 0
  defp structural_nav_action_code(:first_child), do: 1
  defp structural_nav_action_code(:next_sibling), do: 2
  defp structural_nav_action_code(:prev_sibling), do: 3

  @spec update_file_tree(state(), (FileTreeState.t() -> FileTreeState.t())) :: state()
  defp update_file_tree(state, fun) when is_function(fun, 1) do
    EditorState.update_workspace(state, fn ws ->
      SessionState.set_file_tree(ws, fun.(ws.file_tree))
    end)
  end

  @spec visual_line_move(GenServer.server(), state(), :up | :down) :: state()
  defp visual_line_move(buf, state, direction) do
    doc = Buffer.snapshot(buf)
    pos = Document.cursor(doc)
    content_w = content_width(state)
    opts = wrap_opts(buf, width_oracle(state))

    new_pos =
      case direction do
        :down -> Minga.Editing.visual_line_down(doc, pos, content_w, opts)
        :up -> Minga.Editing.visual_line_up(doc, pos, content_w, opts)
      end

    Buffer.move_to(buf, new_pos)
    state
  end

  @spec visual_line_edge(GenServer.server(), state(), :start | :end) :: state()
  defp visual_line_edge(buf, state, edge) do
    doc = Buffer.snapshot(buf)
    pos = Document.cursor(doc)
    content_w = content_width(state)
    opts = wrap_opts(buf, width_oracle(state))

    new_pos =
      case edge do
        :start -> Minga.Editing.visual_line_start(doc, pos, content_w, opts)
        :end -> Minga.Editing.visual_line_end(doc, pos, content_w, opts)
      end

    Buffer.move_to(buf, new_pos)
    state
  end

  @spec logical_line_start(GenServer.server()) :: :ok
  defp logical_line_start(buf) do
    gb = Buffer.snapshot(buf)
    {line, _col} = Document.cursor(gb)
    Buffer.move_to(buf, {line, 0})
  end

  @spec logical_line_end(GenServer.server()) :: :ok
  defp logical_line_end(buf) do
    gb = Buffer.snapshot(buf)
    {line, _col} = Document.cursor(gb)

    end_col =
      case Document.lines(gb, line, 1) do
        [text] when byte_size(text) > 0 -> Unicode.last_grapheme_byte_offset(text)
        _ -> 0
      end

    Buffer.move_to(buf, {line, end_col})
  end

  @spec content_width(state()) :: pos_integer()
  defp content_width(state) do
    layout = Layout.get(state)
    content_w = Layout.active_content_width(layout, state)
    line_count = Buffer.line_count(state.workspace.buffers.active)
    gutter_w = gutter_width(state.workspace.buffers.active, line_count)

    max(content_w - gutter_w, 1)
  end

  @spec gutter_width(pid(), non_neg_integer()) :: non_neg_integer()
  defp gutter_width(buf, line_count) do
    line_number_style =
      try do
        Buffer.get_option(buf, :line_numbers)
      catch
        :exit, _ -> :absolute
      end

    line_number_w =
      if line_number_style == :none do
        0
      else
        Viewport.gutter_width(line_count)
      end

    Gutter.total_width(line_number_w)
  end

  @spec wrapped_scroll_down_line(
          state(),
          pid(),
          Viewport.t(),
          {non_neg_integer(), non_neg_integer()},
          non_neg_integer()
        ) :: {Viewport.t(), {non_neg_integer(), non_neg_integer()}}
  defp wrapped_scroll_down_line(state, buf, vp, cursor, total_lines) do
    content_w = content_width(state)
    oracle = width_oracle(state)
    top_rows = visual_row_count_for_line(buf, vp.top, content_w, oracle)
    current_row = cursor_visual_screen_row(buf, vp, cursor, content_w, oracle)
    new_vp = Viewport.scroll_visual_row_down(vp, top_rows, total_lines, scroll_margin(buf))

    opts = wrap_opts(buf, oracle)

    new_cursor =
      if current_row <= 0 do
        Minga.Editing.visual_line_down(Buffer.snapshot(buf), cursor, content_w, opts)
      else
        cursor
      end

    {new_vp, new_cursor}
  end

  @spec wrapped_scroll_up_line(
          state(),
          pid(),
          Viewport.t(),
          {non_neg_integer(), non_neg_integer()},
          non_neg_integer()
        ) :: {Viewport.t(), {non_neg_integer(), non_neg_integer()}}
  defp wrapped_scroll_up_line(state, buf, vp, cursor, total_lines) do
    content_w = content_width(state)
    oracle = width_oracle(state)
    prev_rows = visual_row_count_for_line(buf, max(vp.top - 1, 0), content_w, oracle)
    current_row = cursor_visual_screen_row(buf, vp, cursor, content_w, oracle)
    new_vp = Viewport.scroll_visual_row_up(vp, prev_rows, total_lines, scroll_margin(buf))
    visible_rows = Viewport.content_rows(vp)

    opts = wrap_opts(buf, oracle)

    new_cursor =
      if current_row >= visible_rows - 1 do
        Minga.Editing.visual_line_up(Buffer.snapshot(buf), cursor, content_w, opts)
      else
        cursor
      end

    {new_vp, new_cursor}
  end

  @spec visual_row_count_for_line(
          pid(),
          non_neg_integer(),
          pos_integer(),
          Minga.Core.WidthOracle.t()
        ) :: pos_integer()
  defp visual_row_count_for_line(buf, line, content_w, oracle) do
    snapshot = Buffer.render_snapshot(buf, line, 1)
    text = List.first(snapshot.lines) || ""
    [entry] = WrapMap.compute([text], content_w, wrap_opts(buf, oracle))
    max(length(entry), 1)
  catch
    :exit, _ -> 1
  end

  @spec cursor_visual_screen_row(
          pid(),
          Viewport.t(),
          {non_neg_integer(), non_neg_integer()},
          pos_integer(),
          Minga.Core.WidthOracle.t()
        ) :: integer()
  defp cursor_visual_screen_row(buf, vp, {cursor_line, cursor_col}, content_w, oracle) do
    line_count = max(cursor_line - vp.top + 1, 1)
    snapshot = Buffer.render_snapshot(buf, vp.top, line_count)
    lines = snapshot.lines
    line_idx = cursor_line - vp.top

    if line_idx < 0 or line_idx >= length(lines) do
      0
    else
      wrap_map = WrapMap.compute(lines, content_w, wrap_opts(buf, oracle))

      cursor_entry =
        Enum.at(wrap_map, line_idx, [
          %{byte_offset: 0, text: "", source_text: "", indent_width: 0}
        ])

      visual_row_idx = visual_row_index(cursor_entry, cursor_col)
      rows_before = wrap_map |> Enum.take(line_idx) |> WrapMap.visual_row_count()
      rows_before + visual_row_idx - vp.visual_row_offset
    end
  catch
    :exit, _ -> 0
  end

  @spec center_wrapped_viewport(
          pid(),
          Viewport.t(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          :center | :top | :bottom,
          Minga.Core.WidthOracle.t()
        ) :: Viewport.t()
  defp center_wrapped_viewport(
         buf,
         vp,
         cursor_line,
         cursor_col,
         content_w,
         _total_lines,
         position,
         oracle
       ) do
    snapshot = Buffer.render_snapshot(buf, cursor_line, 1)
    text = List.first(snapshot.lines) || ""
    [entry] = WrapMap.compute([text], content_w, wrap_opts(buf, oracle))
    cursor_visual_row = visual_row_index(entry, cursor_col)
    visible = Viewport.content_rows(vp)
    target_offset = wrapped_target_offset(cursor_visual_row, visible, position)
    total_visual_rows_to_eof = visual_rows_to_eof(buf, cursor_line, content_w, oracle)
    max_offset = Viewport.max_visual_row_offset(total_visual_rows_to_eof, visible)

    Viewport.put_top_visual(
      vp,
      cursor_line,
      min(target_offset, max_offset),
      max(length(entry), 1)
    )
  catch
    :exit, _ -> vp
  end

  @spec wrapped_target_offset(non_neg_integer(), pos_integer(), :center | :top | :bottom) ::
          non_neg_integer()
  defp wrapped_target_offset(cursor_visual_row, visible, :center) do
    max(cursor_visual_row - div(visible, 2), 0)
  end

  defp wrapped_target_offset(cursor_visual_row, _visible, :top), do: cursor_visual_row

  defp wrapped_target_offset(cursor_visual_row, visible, :bottom) do
    max(cursor_visual_row - visible + 1, 0)
  end

  @spec visual_rows_to_eof(pid(), non_neg_integer(), pos_integer(), Minga.Core.WidthOracle.t()) ::
          pos_integer()
  defp visual_rows_to_eof(buf, start_line, content_w, oracle) do
    total_lines = Buffer.line_count(buf)
    fetch_count = max(total_lines - start_line, 1)
    snapshot = Buffer.render_snapshot(buf, start_line, fetch_count)

    snapshot.lines
    |> WrapMap.compute(content_w, wrap_opts(buf, oracle))
    |> WrapMap.visual_row_count()
    |> max(1)
  catch
    :exit, _ -> 1
  end

  @spec visual_row_index(WrapMap.wrap_entry(), non_neg_integer()) :: non_neg_integer()
  defp visual_row_index(wrap_entry, cursor_col) do
    wrap_entry
    |> Enum.with_index()
    |> Enum.filter(fn {row, _idx} -> row.byte_offset <= cursor_col end)
    |> List.last({%{byte_offset: 0}, 0})
    |> elem(1)
  end

  @spec wrap_opts(pid(), Minga.Core.WidthOracle.t()) :: keyword()
  defp wrap_opts(buf, oracle) do
    [
      breakindent: Buffer.get_option(buf, :breakindent),
      linebreak: Buffer.get_option(buf, :linebreak),
      oracle: oracle,
      tab_width: Buffer.get_option(buf, :tab_width)
    ]
  catch
    :exit, _ -> [breakindent: true, linebreak: true, oracle: oracle, tab_width: 2]
  end

  @spec width_oracle(state()) :: Minga.Core.WidthOracle.t()
  defp width_oracle(state) do
    MingaEditor.Frontend.Capabilities.width_oracle(state.capabilities)
  end

  @spec wrap_enabled?(pid()) :: boolean()
  defp wrap_enabled?(buf) do
    Buffer.get_option(buf, :wrap)
  catch
    :exit, _ -> false
  end

  @spec effective_wrap_enabled?(state(), pid()) :: boolean()
  defp effective_wrap_enabled?(state, buf) do
    wrap_enabled?(buf) and not wrap_disabled_by_active_window?(state, buf)
  end

  @spec wrap_disabled_by_active_window?(state(), pid()) :: boolean()
  defp wrap_disabled_by_active_window?(state, buf) do
    case EditorState.active_window_struct(state) do
      nil ->
        false

      %Window{fold_map: fold_map} = window ->
        if FoldMap.empty?(fold_map) do
          try do
            DisplayMap.required?(window.fold_map, Buffer.decorations(buf))
          catch
            :exit, _ -> false
          end
        else
          true
        end
    end
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
    {cursor_line, _col} = Buffer.cursor(buf)

    if FoldMap.folded?(fm, cursor_line) do
      target = fold_skip_target(fm, cursor_line, direction)
      Buffer.move_to(buf, {target, 0})
    end

    state
  end

  @spec fold_skip_target(FoldMap.t(), non_neg_integer(), :up | :down) :: non_neg_integer()
  defp fold_skip_target(fm, cursor_line, :down), do: FoldMap.next_visible(fm, cursor_line - 1)
  defp fold_skip_target(fm, cursor_line, :up), do: FoldMap.prev_visible(fm, cursor_line + 1)

  # ── Viewport helpers for scroll commands ──────────────────────────────────

  # Delegates to EditorState shared helpers.
  defp active_viewport(state), do: EditorState.current_viewport(state)

  defp put_active_viewport(state, new_vp),
    do: EditorState.update_current_viewport(state, new_vp)

  @spec scroll_margin(pid()) :: non_neg_integer()
  defp scroll_margin(buf) do
    Buffer.get_option(buf, :scroll_margin)
  catch
    :exit, _ -> 5
  end

  # Computes the effective page delta in buffer lines, accounting for
  # decorations that consume display rows. Falls back to raw display_rows
  # when no decorations exist (fast path).
  @spec decoration_aware_page_delta(pid(), Viewport.t(), pos_integer()) :: pos_integer()
  defp decoration_aware_page_delta(buf, _vp, display_rows) do
    decorations = Buffer.decorations(buf)
    {cursor_line, _} = Buffer.cursor(buf)
    total = Buffer.line_count(buf)
    Viewport.effective_page_lines(cursor_line, display_rows, decorations, total)
  catch
    :exit, _ -> display_rows
  end

  # When G is pressed in an agent chat window, re-pin so streaming
  # auto-follows again. For normal buffer windows this is a no-op.
  @spec maybe_repin_agent_chat(state()) :: state()
  defp maybe_repin_agent_chat(state) do
    case EditorState.active_window_struct(state) do
      %Window{id: win_id, content: {:agent_chat, _}} ->
        EditorState.update_window(state, win_id, &Window.set_pinned(&1, true))

      _ ->
        state
    end
  end

  commands(@command_specs)
end
