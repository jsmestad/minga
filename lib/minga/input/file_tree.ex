defmodule Minga.Input.FileTree do
  @moduledoc """
  Input handler for the file tree panel.

  When the file tree is open and focused, intercepts tree-specific keys
  (Enter, Tab, h, l, H, r/g, q/Escape) and syncs the FileTree data structure
  with the backing `*File Tree*` buffer. Navigation keys (j, k) are handled
  by moving the buffer cursor, which syncs the tree cursor.

  Unhandled keys pass through to the next handler in the focus stack,
  unfocusing the tree first so normal editing resumes.
  """

  @behaviour Minga.Input.Handler

  alias Minga.Editor.Commands
  alias Minga.FileTree
  alias Minga.FileTree.BufferSync

  @escape 27
  @enter 13
  @tab 9

  @impl true
  @spec handle_key(Minga.Editor.State.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()
  def handle_key(%{file_tree: %FileTree{}, file_tree_focused: true} = state, cp, mods) do
    case do_handle(state, cp, mods) do
      :passthrough ->
        # Unfocus tree and pass through to the next handler
        {:passthrough, %{state | file_tree_focused: false}}

      new_state ->
        {:handled, new_state}
    end
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end

  @spec do_handle(Minga.Editor.State.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Editor.State.t() | :passthrough

  # q or Escape: close the tree
  defp do_handle(%{file_tree_buffer: buf} = state, cp, _mods) when cp in [?q, @escape] do
    if is_pid(buf), do: GenServer.stop(buf, :normal)
    %{state | file_tree: nil, file_tree_focused: false, file_tree_buffer: nil}
  end

  # j: move down (update tree cursor, sync to buffer)
  defp do_handle(%{file_tree: tree} = state, ?j, _mods) do
    new_tree = FileTree.move_down(tree)
    sync_and_update(state, new_tree)
  end

  # k: move up (update tree cursor, sync to buffer)
  defp do_handle(%{file_tree: tree} = state, ?k, _mods) do
    new_tree = FileTree.move_up(tree)
    sync_and_update(state, new_tree)
  end

  # Enter: open file or toggle directory
  defp do_handle(%{file_tree: tree} = state, @enter, _mods) do
    case FileTree.selected_entry(tree) do
      %{dir?: true} ->
        new_tree = FileTree.toggle_expand(tree)
        sync_and_update(state, new_tree)

      %{dir?: false, path: path} ->
        state = %{state | file_tree_focused: false}

        case Commands.start_buffer(path) do
          {:ok, pid} ->
            Minga.Editor.do_file_tree_open(state, pid, path, tree)

          {:error, _} ->
            state
        end

      nil ->
        state
    end
  end

  # Tab: toggle directory expand
  defp do_handle(%{file_tree: tree} = state, @tab, _mods) do
    new_tree = FileTree.toggle_expand(tree)
    sync_and_update(state, new_tree)
  end

  # h: collapse
  defp do_handle(%{file_tree: tree} = state, ?h, _mods) do
    new_tree = FileTree.collapse(tree)
    sync_and_update(state, new_tree)
  end

  # l: expand
  defp do_handle(%{file_tree: tree} = state, ?l, _mods) do
    new_tree = FileTree.expand(tree)
    sync_and_update(state, new_tree)
  end

  # H: toggle hidden files
  defp do_handle(%{file_tree: tree} = state, ?H, _mods) do
    new_tree = FileTree.toggle_hidden(tree)
    sync_and_update(state, new_tree)
  end

  # r or g: refresh
  defp do_handle(%{file_tree: tree} = state, cp, _mods) when cp in [?r, ?g] do
    new_tree = FileTree.refresh(tree)
    sync_and_update(state, new_tree)
  end

  # Any other key: pass through
  defp do_handle(_state, _cp, _mods), do: :passthrough

  # Update the tree in state and sync the buffer
  @spec sync_and_update(Minga.Editor.State.t(), FileTree.t()) :: Minga.Editor.State.t()
  defp sync_and_update(%{file_tree_buffer: buf} = state, new_tree) when is_pid(buf) do
    BufferSync.sync(buf, new_tree)
    %{state | file_tree: new_tree}
  end

  defp sync_and_update(state, new_tree) do
    %{state | file_tree: new_tree}
  end
end
