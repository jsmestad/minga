defmodule Minga.Input.FileTreeHandler do
  @moduledoc """
  Input handler for the file tree scope.

  Handles file tree key bindings (scope trie resolution) and mouse
  interactions (click to open/toggle, scroll wheel). Delegates vim
  navigation keys (j/k/gg/G/Ctrl-d) to the mode FSM with the tree
  buffer swapped in as the active buffer.
  """

  @behaviour Minga.Input.Handler

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands
  alias Minga.Editor.Layout
  alias Minga.Editor.State, as: EditorState
  alias Minga.Input
  alias Minga.Keymap.Scope
  alias Minga.Project.FileTree
  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}

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
          EditorState.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: {:handled, EditorState.t()} | {:passthrough, EditorState.t()}

  # File tree: left click opens file/toggles dir, scroll wheel scrolls tree
  def handle_mouse(
        %{workspace: %{keymap_scope: :file_tree, file_tree: %{tree: %FileTree{} = tree}}} = state,
        row,
        col,
        button,
        _mods,
        :press,
        click_count
      ) do
    layout = Layout.get(state)

    case layout.file_tree do
      nil ->
        {:passthrough, state}

      {ft_row, ft_col, ft_width, ft_height} ->
        if row >= ft_row and row < ft_row + ft_height and col >= ft_col and
             col < ft_col + ft_width do
          {:handled,
           handle_file_tree_click(state, tree, row, ft_row, ft_height, button, click_count)}
        else
          {:passthrough, state}
        end
    end
  end

  # All other scopes
  def handle_mouse(state, _row, _col, _button, _mods, _event_type, _cc) do
    {:passthrough, state}
  end

  # ── File tree key dispatch ─────────────────────────────────────────────

  @spec handle_file_tree_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}
  defp handle_file_tree_key(state, cp, mods) do
    if Input.key_sequence_pending?(state) do
      {:handled, delegate_to_mode_fsm_with_tree_buffer(state, cp, mods)}
    else
      key = {cp, mods}

      vim_state =
        if Minga.Editing.active_model() == Minga.Editing.Model.CUA, do: :cua, else: :normal

      case Scope.resolve_key(:file_tree, vim_state, key) do
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
    state = put_in(state.workspace.buffers.active, buf)
    state = Minga.Editor.do_handle_key(state, cp, mods)

    state =
      if Minga.Editing.mode(state) != :normal do
        EditorState.transition_mode(state, :normal)
      else
        state
      end

    state = put_in(state.workspace.buffers.active, real_active)

    if state.workspace.file_tree.tree == nil do
      state
    else
      sync_tree_cursor_from_buffer(state, buf)
    end
  end

  defp delegate_to_mode_fsm_with_tree_buffer(state, _cp, _mods), do: state

  @spec sync_tree_cursor_from_buffer(EditorState.t(), pid()) :: EditorState.t()
  defp sync_tree_cursor_from_buffer(%{workspace: %{file_tree: %{tree: tree}}} = state, buf) do
    {cursor_line, _col} = BufferServer.cursor(buf)
    entries = FileTree.visible_entries(tree)
    max_cursor = max(length(entries) - 1, 0)
    clamped = min(cursor_line, max_cursor)
    put_in(state.workspace.file_tree.tree, %{tree | cursor: clamped})
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
    entries = FileTree.visible_entries(tree)
    max_idx = max(length(entries) - 1, 0)
    new_cursor = (tree.cursor + delta) |> max(0) |> min(max_idx)
    put_in(state.workspace.file_tree.tree, %{tree | cursor: new_cursor})
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
          new_tree = %{tree | cursor: entry_idx}
          state = put_in(state.workspace.file_tree.tree, new_tree)
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

  # ── Shared helpers ──────────────────────────────────────────────────────
end
