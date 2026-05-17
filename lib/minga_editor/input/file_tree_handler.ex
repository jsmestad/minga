defmodule MingaEditor.Input.FileTreeHandler do
  @moduledoc """
  Input handler for the file tree scope.

  Handles file tree key bindings (scope trie resolution) and mouse
  interactions (click to open/toggle, scroll wheel). Delegates vim
  navigation keys (j/k/gg/G/Ctrl-d) to the mode FSM with the tree
  buffer swapped in as the active buffer.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  alias Minga.Buffer
  alias MingaEditor.Commands
  alias MingaEditor.FocusTree
  alias MingaEditor.FocusTree.Node, as: FocusNode
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.Input
  alias Minga.Keymap
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.BufferSync
  alias MingaEditor.Workspace.State, as: WorkspaceState
  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()

  # Help overlay active: capture keys so Escape closes help instead of closing the tree.
  def handle_key(
        %{workspace: %{keymap_scope: :file_tree, file_tree: %{help_visible: true}}} = state,
        cp,
        mods
      ) do
    {:handled, handle_help_key(state, cp, mods)}
  end

  # Inline editing active: capture all keys before they reach the mode FSM or scope trie
  def handle_key(
        %{workspace: %{keymap_scope: :file_tree, file_tree: %{editing: %{} = _editing}}} = state,
        cp,
        mods
      ) do
    {:handled, handle_inline_edit_key(state, cp, mods)}
  end

  # Filter input active: capture text before it reaches vim search.
  def handle_key(
        %{workspace: %{keymap_scope: :file_tree, file_tree: %{filtering: true}}} = state,
        cp,
        mods
      ) do
    {:handled, handle_filter_key(state, cp, mods)}
  end

  # File tree scope with tree focused
  def handle_key(
        %{workspace: %{keymap_scope: :file_tree, file_tree: %{tree: %FileTree{}, focused: true}}} =
          state,
        cp,
        mods
      ) do
    handle_file_tree_key(state, cp, mods)
  end

  # File tree scope but not focused
  def handle_key(%{workspace: %{keymap_scope: :file_tree}} = state, _cp, _mods) do
    {:passthrough, state}
  end

  # Not file tree scope
  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  @impl true
  @spec handle_mouse(
          state(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: MingaEditor.Input.Handler.result()

  def handle_mouse(state, row, col, button, mods, event_type, click_count) do
    case routed_file_tree_node(state, row, col, button) do
      %FocusNode{} = node ->
        handle_mouse_at_node(state, node, row, col, button, mods, event_type, click_count)

      nil ->
        {:passthrough, state}
    end
  end

  @impl true
  @spec handle_mouse_at_node(
          state(),
          FocusNode.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: MingaEditor.Input.Handler.result()

  # File tree: left click opens file/toggles dir, scroll wheel scrolls tree.
  def handle_mouse_at_node(
        %{workspace: %{file_tree: %{tree: %FileTree{} = tree}}} = state,
        %FocusNode{content_type: :file_tree, rect: {ft_row, _ft_col, _ft_width, ft_height}},
        row,
        _col,
        button,
        _mods,
        :press,
        click_count
      ) do
    state = focus_file_tree_for_mouse(state, button)
    {:handled, handle_file_tree_click(state, tree, row, ft_row, ft_height, button, click_count)}
  end

  def handle_mouse_at_node(state, _node, _row, _col, _button, _mods, _event_type, _cc) do
    {:passthrough, state}
  end

  @spec routed_file_tree_node(EditorState.t(), integer(), integer(), atom()) ::
          FocusNode.t() | nil
  defp routed_file_tree_node(state, row, col, button) do
    tree = FocusTree.from_state(state)

    path =
      if button in [:wheel_down, :wheel_up],
        do: FocusTree.scroll_path(tree, row, col),
        else: FocusTree.hit_path(tree, row, col)

    Enum.find(path, &(&1.handler == __MODULE__))
  end

  @spec focus_file_tree_for_mouse(EditorState.t(), atom()) :: EditorState.t()
  defp focus_file_tree_for_mouse(state, :left) do
    EditorState.update_workspace(state, fn workspace ->
      workspace
      |> WorkspaceState.set_file_tree(FileTreeState.focus(workspace.file_tree))
      |> WorkspaceState.set_keymap_scope(:file_tree)
    end)
  end

  defp focus_file_tree_for_mouse(state, _button), do: state

  # ── File tree key dispatch ─────────────────────────────────────────────

  @spec handle_file_tree_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  defp handle_file_tree_key(state, cp, mods) do
    if Input.key_sequence_pending?(state) do
      {:handled, delegate_to_mode_fsm_with_tree_buffer(state, cp, mods)}
    else
      key = {cp, mods}

      vim_state =
        if Minga.Editing.active_model(state) == Minga.Editing.Model.CUA, do: :cua, else: :normal

      case Keymap.resolve_scoped_key(
             :file_tree,
             vim_state,
             key,
             EditorState.keymap_context(state)
           ) do
        {:command, command} ->
          {:handled, Commands.execute(state, command)}

        {:prefix, _node} ->
          {:handled, state}

        :not_found ->
          {:handled, delegate_to_mode_fsm_with_tree_buffer(state, cp, mods)}
      end
    end
  end

  @spec delegate_to_mode_fsm_with_tree_buffer(
          EditorState.t(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          EditorState.t()
  defp delegate_to_mode_fsm_with_tree_buffer(
         %{workspace: %{file_tree: %{buffer: buf}}} = state,
         cp,
         mods
       )
       when is_pid(buf) do
    real_active = state.workspace.buffers.active
    state = set_active_buffer_override(state, buf)
    state = MingaEditor.do_handle_key(state, cp, mods)

    state =
      if Minga.Editing.mode(state) != :normal do
        EditorState.transition_mode(state, :normal)
      else
        state
      end

    state = set_active_buffer_override(state, real_active)

    if state.workspace.file_tree.tree == nil do
      state
    else
      sync_tree_cursor_from_buffer(state, buf)
    end
  end

  defp delegate_to_mode_fsm_with_tree_buffer(state, _cp, _mods), do: state

  @spec sync_tree_cursor_from_buffer(EditorState.t(), pid()) :: EditorState.t()
  defp sync_tree_cursor_from_buffer(%{workspace: %{file_tree: %{tree: tree}}} = state, buf) do
    {cursor_line, _col} = Buffer.cursor(buf)

    update_file_tree(state, &FileTreeState.set_tree(&1, FileTree.select(tree, cursor_line)))
  end

  # ── File tree mouse helpers ────────────────────────────────────────────

  @spec handle_file_tree_click(
          EditorState.t(),
          FileTree.t(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          atom(),
          pos_integer()
        ) :: EditorState.t()
  defp handle_file_tree_click(state, tree, _row, _ft_row, _ft_height, button, _click_count)
       when button in [:wheel_up, :wheel_down] do
    delta = if button == :wheel_down, do: 3, else: -3

    update_file_tree(
      state,
      &FileTreeState.set_tree(&1, FileTree.select(tree, tree.cursor + delta))
    )
  end

  defp handle_file_tree_click(state, tree, row, ft_row, ft_height, :left, click_count) do
    content_rows = ft_height - 1
    screen_row = row - ft_row - 1

    if screen_row < 0 do
      state
    else
      scroll_offset = tree_scroll_offset(tree.cursor, content_rows)
      entry_idx = scroll_offset + screen_row
      entries = FileTree.visible_entries(tree)

      case Enum.at(entries, entry_idx) do
        nil ->
          state

        entry ->
          state =
            update_file_tree(state, &FileTreeState.set_tree(&1, FileTree.select(tree, entry_idx)))

          handle_tree_entry_click(state, entry, click_count)
      end
    end
  end

  defp handle_file_tree_click(state, _tree, _row, _ft_row, _ft_height, _button, _cc), do: state

  @spec handle_tree_entry_click(EditorState.t(), FileTree.entry(), pos_integer()) ::
          EditorState.t()
  defp handle_tree_entry_click(state, %{dir?: true}, _click_count) do
    Commands.execute(state, :tree_toggle_directory)
  end

  defp handle_tree_entry_click(state, %{dir?: false}, _click_count) do
    Commands.execute(state, :tree_open_or_toggle)
  end

  @spec tree_scroll_offset(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp tree_scroll_offset(cursor, visible_rows) when visible_rows <= 0, do: cursor
  defp tree_scroll_offset(cursor, visible_rows) when cursor < visible_rows, do: 0
  defp tree_scroll_offset(cursor, visible_rows), do: cursor - visible_rows + 1

  # ── Inline editing key handler ──────────────────────────────────────────

  @enter 13
  @escape 27
  @backspace 127

  @spec handle_inline_edit_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  defp handle_inline_edit_key(state, @enter, 0) do
    Commands.FileTree.confirm_editing(state)
  end

  defp handle_inline_edit_key(state, @escape, 0) do
    Commands.FileTree.cancel_editing(state)
  end

  defp handle_inline_edit_key(state, @backspace, 0) do
    editing = state.workspace.file_tree.editing

    if editing.text == "" do
      Commands.FileTree.cancel_editing(state)
    else
      # Delete the last grapheme from the editing text.
      # Use String.slice/3 (start, length) to avoid negative index issues.
      new_text = String.slice(editing.text, 0, max(String.length(editing.text) - 1, 0))
      ft = FileTreeState.update_editing_text(state.workspace.file_tree, new_text)
      set_file_tree(state, ft)
    end
  end

  # Printable characters: append to editing text
  defp handle_inline_edit_key(state, cp, 0) when cp >= 32 do
    char = <<cp::utf8>>
    editing = state.workspace.file_tree.editing
    new_text = editing.text <> char
    ft = FileTreeState.update_editing_text(state.workspace.file_tree, new_text)
    set_file_tree(state, ft)
  end

  # All other keys (with modifiers, control chars): swallow them
  defp handle_inline_edit_key(state, _cp, _mods), do: state

  # ── Help and filter key handlers ────────────────────────────────────────

  @spec handle_help_key(EditorState.t(), non_neg_integer(), non_neg_integer()) :: EditorState.t()
  defp handle_help_key(state, @escape, 0), do: Commands.FileTree.hide_help(state)
  defp handle_help_key(state, ??, 0), do: Commands.FileTree.toggle_help(state)
  defp handle_help_key(state, _cp, _mods), do: state

  @spec handle_filter_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  defp handle_filter_key(state, @enter, 0) do
    set_file_tree(state, FileTreeState.accept_filter(state.workspace.file_tree))
  end

  defp handle_filter_key(state, @escape, 0) do
    set_file_tree(state, FileTreeState.clear_filter(state.workspace.file_tree))
  end

  defp handle_filter_key(state, @backspace, 0) do
    text = current_filter_text(state)

    if text == "" do
      set_file_tree(state, FileTreeState.clear_filter(state.workspace.file_tree))
    else
      new_text = String.slice(text, 0, max(String.length(text) - 1, 0))
      set_file_tree(state, FileTreeState.update_filter(state.workspace.file_tree, new_text))
    end
  end

  defp handle_filter_key(state, cp, 0) when cp >= 32 do
    new_text = current_filter_text(state) <> <<cp::utf8>>
    set_file_tree(state, FileTreeState.update_filter(state.workspace.file_tree, new_text))
  end

  defp handle_filter_key(state, _cp, _mods), do: state

  @spec current_filter_text(EditorState.t()) :: String.t()
  defp current_filter_text(%{workspace: %{file_tree: %{tree: %FileTree{filter: filter}}}})
       when is_binary(filter), do: filter

  defp current_filter_text(_state), do: ""

  # ── Shared helpers ──────────────────────────────────────────────────────

  @spec set_active_buffer_override(EditorState.t(), pid() | nil) :: EditorState.t()
  defp set_active_buffer_override(state, pid) do
    EditorState.update_workspace(state, fn ws ->
      WorkspaceState.set_buffers(ws, Buffers.set_active_override(ws.buffers, pid))
    end)
  end

  @spec set_file_tree(EditorState.t(), FileTreeState.t()) :: EditorState.t()
  defp set_file_tree(state, file_tree) do
    sync_buffer(file_tree)
    EditorState.update_workspace(state, &WorkspaceState.set_file_tree(&1, file_tree))
  end

  @spec sync_buffer(FileTreeState.t()) :: :ok
  defp sync_buffer(%FileTreeState{buffer: buffer, tree: %FileTree{} = tree})
       when is_pid(buffer) do
    BufferSync.sync(buffer, tree)
  catch
    :exit, _reason -> :ok
  end

  defp sync_buffer(%FileTreeState{}), do: :ok

  @spec update_file_tree(EditorState.t(), (FileTreeState.t() -> FileTreeState.t())) ::
          EditorState.t()
  defp update_file_tree(state, fun) when is_function(fun, 1) do
    EditorState.update_workspace(state, fn ws ->
      WorkspaceState.set_file_tree(ws, fun.(ws.file_tree))
    end)
  end
end
