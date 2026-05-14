defmodule MingaEditor.FileTree.Rows do
  @moduledoc """
  Builds semantic file-tree rows from pure tree data and editor state.

  `Minga.Project.FileTree` owns filesystem topology. This module adds Layer 2 presentation semantics such as selection, focus, active file, dirty buffers, git status, and inline editing.
  """

  alias Minga.Buffer
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.GitStatus
  alias MingaEditor.FileTree.Row
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState

  @type options :: [
          selected_index: non_neg_integer(),
          focused: boolean(),
          active_path: String.t() | nil,
          dirty_paths: MapSet.t(String.t()),
          git_status: GitStatus.status_map(),
          editing: FileTreeState.editing() | nil
        ]

  @doc "Builds semantic rows from a pure file tree and explicit presentation inputs."
  @spec from_tree(FileTree.t(), options()) :: [Row.t()]
  def from_tree(%FileTree{} = tree, opts \\ []) do
    git_status = Keyword.get(opts, :git_status, tree.git_status)
    dirty_paths = Keyword.get(opts, :dirty_paths, MapSet.new())
    active_path = opts |> Keyword.get(:active_path) |> expand_optional_path()
    selected_index = Keyword.get(opts, :selected_index, tree.cursor)
    focused = Keyword.get(opts, :focused, false)
    editing = Keyword.get(opts, :editing)

    tree
    |> FileTree.visible_entries()
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} ->
      row_from_entry(entry, index, tree, %{
        active_path: active_path,
        dirty_paths: dirty_paths,
        editing: editing,
        focused: focused,
        git_status: git_status,
        selected_index: selected_index
      })
    end)
  end

  @doc "Builds semantic rows from editor state when the file tree is open."
  @spec from_state(EditorState.t() | map()) :: [Row.t()]
  def from_state(%{workspace: %{file_tree: %{tree: nil}}}), do: []

  def from_state(%{workspace: %{file_tree: %{tree: %FileTree{} = tree} = file_tree}} = state) do
    from_tree(tree,
      active_path: active_buffer_path(state),
      dirty_paths: dirty_paths(state),
      editing: Map.get(file_tree, :editing),
      focused: Map.get(file_tree, :focused, false),
      git_status: tree.git_status,
      selected_index: tree.cursor
    )
  end

  def from_state(_state), do: []

  @spec row_from_entry(FileTree.entry(), non_neg_integer(), FileTree.t(), map()) :: Row.t()
  defp row_from_entry(entry, index, tree, opts) do
    path = Path.expand(entry.path)

    Row.new(
      id: Row.id_for(entry),
      path: path,
      relative_path: Path.relative_to(path, tree.root),
      name: entry.name,
      directory?: entry.dir?,
      expanded?: entry.dir? and MapSet.member?(tree.expanded, path),
      selected?: index == opts.selected_index,
      focused?: opts.focused,
      active?: active?(path, opts.active_path),
      dirty?: dirty?(entry, path, opts.dirty_paths),
      git_status: Map.get(opts.git_status, path),
      depth: entry.depth,
      guides: entry.guides,
      last_child?: entry.last_child?,
      editing: editing_for_index(index, opts.editing)
    )
  end

  @spec active?(String.t(), String.t() | nil) :: boolean()
  defp active?(_path, nil), do: false
  defp active?(path, active_path), do: path == active_path

  @spec dirty?(FileTree.entry(), String.t(), MapSet.t(String.t())) :: boolean()
  defp dirty?(%{dir?: true}, _path, _dirty_paths), do: false
  defp dirty?(_entry, path, dirty_paths), do: MapSet.member?(dirty_paths, path)

  @spec editing_for_index(non_neg_integer(), FileTreeState.editing() | nil) ::
          FileTreeState.editing() | nil
  defp editing_for_index(_index, nil), do: nil
  defp editing_for_index(index, %{index: index} = editing), do: editing
  defp editing_for_index(_index, _editing), do: nil

  @spec expand_optional_path(String.t() | nil) :: String.t() | nil
  defp expand_optional_path(nil), do: nil
  defp expand_optional_path(path), do: Path.expand(path)

  @spec active_buffer_path(EditorState.t() | map()) :: String.t() | nil
  defp active_buffer_path(%{workspace: %{buffers: %{active: nil}}}), do: nil

  defp active_buffer_path(%{workspace: %{buffers: %{active: buf}}}) do
    case Buffer.file_path(buf) do
      nil -> nil
      path -> Path.expand(path)
    end
  end

  defp active_buffer_path(_state), do: nil

  defp dirty_paths(%{workspace: %{buffers: %{list: buffer_list}}}) do
    buffer_list
    |> Enum.flat_map(&dirty_buffer_path/1)
    |> Enum.map(&Path.expand/1)
    |> MapSet.new()
  end

  defp dirty_paths(_state), do: MapSet.new()

  @spec dirty_buffer_path(pid()) :: [String.t()]
  defp dirty_buffer_path(pid) when is_pid(pid) do
    if Buffer.dirty?(pid), do: present_path(Buffer.file_path(pid)), else: []
  catch
    :exit, _ -> []
  end

  @spec present_path(String.t() | nil) :: [String.t()]
  defp present_path(nil), do: []
  defp present_path(path), do: [path]
end
