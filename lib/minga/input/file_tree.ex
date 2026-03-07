defmodule Minga.Input.FileTree do
  @moduledoc """
  Input handler for the file tree panel.

  When the file tree is focused, intercepts tree-specific keys (Enter,
  Tab, h/l for expand/collapse, H for hidden, r/g for refresh, q/Esc
  to close). All other keys are delegated to the mode FSM with the
  file tree buffer temporarily set as the active buffer. After mode FSM
  processing, the buffer cursor position is synced back to the tree
  cursor so the two stay in lockstep.

  This gives the file tree full vim navigation (gg, G, j, k, Ctrl-d,
  Ctrl-u, /, etc.) for free.
  """

  @behaviour Minga.Input.Handler

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.FileTree
  alias Minga.FileTree.BufferSync

  @escape 27
  @enter 13
  @tab 9

  @impl true
  @spec handle_key(Minga.Editor.State.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()
  def handle_key(%{file_tree: %{tree: %FileTree{}, focused: true}} = state, cp, mods) do
    # If a leader key sequence is in progress (key_buffer is non-empty),
    # delegate everything to the mode FSM so SPC w l, SPC o p, etc. work.
    if key_sequence_pending?(state) do
      {:handled, delegate_to_mode_fsm(state, cp, mods)}
    else
      case do_handle(state, cp, mods) do
        {:tree_handled, new_state} ->
          {:handled, new_state}

        :delegate_to_fsm ->
          {:handled, delegate_to_mode_fsm(state, cp, mods)}
      end
    end
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end

  @spec do_handle(Minga.Editor.State.t(), non_neg_integer(), non_neg_integer()) ::
          {:tree_handled, Minga.Editor.State.t()} | :delegate_to_fsm

  # q or Escape: close the tree
  defp do_handle(%{file_tree: %{buffer: buf}} = state, cp, _mods) when cp in [?q, @escape] do
    if is_pid(buf), do: GenServer.stop(buf, :normal)
    {:tree_handled, %{state | file_tree: FileTreeState.close(state.file_tree)}}
  end

  # Enter: open file or toggle directory
  defp do_handle(%{file_tree: %{tree: tree}} = state, @enter, _mods) do
    case FileTree.selected_entry(tree) do
      %{dir?: true} ->
        new_tree = FileTree.toggle_expand(tree)
        {:tree_handled, sync_and_update(state, new_tree)}

      %{dir?: false, path: path} ->
        state = put_in(state.file_tree.focused, false)

        new_state =
          case Commands.start_buffer(path) do
            {:ok, pid} -> Minga.Editor.do_file_tree_open(state, pid, path, tree)
            {:error, _} -> state
          end

        {:tree_handled, new_state}

      nil ->
        {:tree_handled, state}
    end
  end

  # Tab: toggle directory expand
  defp do_handle(%{file_tree: %{tree: tree}} = state, @tab, _mods) do
    new_tree = FileTree.toggle_expand(tree)
    {:tree_handled, sync_and_update(state, new_tree)}
  end

  # l: expand directory (tree-specific, not vim right)
  defp do_handle(%{file_tree: %{tree: tree}} = state, ?l, _mods) do
    new_tree = FileTree.expand(tree)
    {:tree_handled, sync_and_update(state, new_tree)}
  end

  # h: collapse directory (tree-specific, not vim left)
  defp do_handle(%{file_tree: %{tree: tree}} = state, ?h, _mods) do
    new_tree = FileTree.collapse(tree)
    {:tree_handled, sync_and_update(state, new_tree)}
  end

  # H: toggle hidden files
  defp do_handle(%{file_tree: %{tree: tree}} = state, ?H, _mods) do
    new_tree = FileTree.toggle_hidden(tree)
    {:tree_handled, sync_and_update(state, new_tree)}
  end

  # r: refresh (g is reserved for gg motion)
  defp do_handle(%{file_tree: %{tree: tree}} = state, cp, _mods) when cp == ?r do
    new_tree = FileTree.refresh(tree)
    {:tree_handled, sync_and_update(state, new_tree)}
  end

  # Everything else: delegate to mode FSM for vim navigation
  defp do_handle(_state, _cp, _mods), do: :delegate_to_fsm

  # Is a multi-key sequence (leader key, operator pending, g-prefix, etc.) in progress?
  @spec key_sequence_pending?(Minga.Editor.State.t()) :: boolean()
  defp key_sequence_pending?(%{mode_state: %{leader_node: node}}) when node != nil, do: true
  defp key_sequence_pending?(%{mode_state: %{pending_g: true}}), do: true
  defp key_sequence_pending?(%{mode: mode}) when mode in [:operator_pending, :command], do: true
  defp key_sequence_pending?(_state), do: false

  # ── Mode FSM delegation ────────────────────────────────────────────────

  @spec delegate_to_mode_fsm(Minga.Editor.State.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Editor.State.t()
  defp delegate_to_mode_fsm(%{file_tree: %{buffer: buf}} = state, cp, mods) when is_pid(buf) do
    # Save the real active buffer, swap in the tree buffer
    real_active = state.buffers.active
    state = put_in(state.buffers.active, buf)

    # Run through the mode FSM (j, k, gg, G, Ctrl-d, Ctrl-u, /, etc.)
    state = Minga.Editor.do_handle_key(state, cp, mods)

    # Block mode transitions: force back to normal if mode FSM tried
    # to enter insert/visual/etc. (tree is read-only)
    state =
      if state.mode != :normal do
        %{state | mode: :normal, mode_state: Minga.Mode.initial_state()}
      else
        state
      end

    # Restore the real active buffer
    state = put_in(state.buffers.active, real_active)

    # If the tree was closed by the command (e.g. SPC o p toggle), skip sync
    if state.file_tree.tree == nil do
      state
    else
      sync_tree_cursor_from_buffer(state, buf)
    end
  end

  defp delegate_to_mode_fsm(state, _cp, _mods), do: state

  # Read the buffer cursor line and update the tree cursor to match
  @spec sync_tree_cursor_from_buffer(Minga.Editor.State.t(), pid()) :: Minga.Editor.State.t()
  defp sync_tree_cursor_from_buffer(%{file_tree: %{tree: tree}} = state, buf) do
    {cursor_line, _col} = BufferServer.cursor(buf)
    entries = FileTree.visible_entries(tree)
    max_cursor = max(length(entries) - 1, 0)
    clamped = min(cursor_line, max_cursor)
    put_in(state.file_tree.tree, %{tree | cursor: clamped})
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  @spec sync_and_update(Minga.Editor.State.t(), FileTree.t()) :: Minga.Editor.State.t()
  defp sync_and_update(%{file_tree: %{buffer: buf}} = state, new_tree) when is_pid(buf) do
    BufferSync.sync(buf, new_tree)
    put_in(state.file_tree.tree, new_tree)
  end

  defp sync_and_update(state, new_tree) do
    put_in(state.file_tree.tree, new_tree)
  end
end
