defmodule Minga.Input.FileTree do
  @moduledoc """
  Input handler for the file tree panel.

  When the file tree is open and focused, intercepts navigation keys
  (j, k, h, l), action keys (Enter, Tab, H, r/g), and close keys
  (q, Escape). Unhandled keys pass through to the next handler in
  the stack (which unfocuses the tree first).

  This handler will be removed when the file tree is converted to a
  real buffer (issue #130 step 3).
  """

  @behaviour Minga.Input.Handler

  alias Minga.Editor.Commands
  alias Minga.FileTree

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
  defp do_handle(state, cp, _mods) when cp in [?q, @escape] do
    %{state | file_tree: nil, file_tree_focused: false}
  end

  # j: move down
  defp do_handle(%{file_tree: tree} = state, ?j, _mods) do
    %{state | file_tree: FileTree.move_down(tree)}
  end

  # k: move up
  defp do_handle(%{file_tree: tree} = state, ?k, _mods) do
    %{state | file_tree: FileTree.move_up(tree)}
  end

  # Enter: open file or toggle directory
  defp do_handle(%{file_tree: tree} = state, @enter, _mods) do
    case FileTree.selected_entry(tree) do
      %{dir?: true} ->
        %{state | file_tree: FileTree.toggle_expand(tree)}

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
    %{state | file_tree: FileTree.toggle_expand(tree)}
  end

  # h: collapse
  defp do_handle(%{file_tree: tree} = state, ?h, _mods) do
    %{state | file_tree: FileTree.collapse(tree)}
  end

  # l: expand
  defp do_handle(%{file_tree: tree} = state, ?l, _mods) do
    %{state | file_tree: FileTree.expand(tree)}
  end

  # H: toggle hidden files
  defp do_handle(%{file_tree: tree} = state, ?H, _mods) do
    %{state | file_tree: FileTree.toggle_hidden(tree)}
  end

  # r or g: refresh
  defp do_handle(%{file_tree: tree} = state, cp, _mods) when cp in [?r, ?g] do
    %{state | file_tree: FileTree.refresh(tree)}
  end

  # Any other key: pass through
  defp do_handle(_state, _cp, _mods), do: :passthrough
end
