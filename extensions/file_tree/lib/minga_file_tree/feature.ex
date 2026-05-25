defmodule MingaFileTree.Feature do
  @moduledoc """
  FileTree feature ownership adapter.

  FileTree is still implemented in core, but its UI state, input handler, and sidebar contribution are registered through the same source-owned paths that a bundled extension will use after extraction.
  """

  alias Minga.Extension.ContributionCleanup
  alias Minga.Keymap.Scope
  alias Minga.Project.FileTree
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Extension.Sidebar.Snapshot
  alias MingaEditor.Input
  alias MingaFileTree.Input.Handler
  alias MingaFileTree.Rows
  alias MingaFileTree.State, as: FileTreeState

  @source {:extension, :minga_file_tree}
  @input_source {:extension, :minga_file_tree}
  @feature_id :file_tree
  @sidebar_id "file_tree"

  @doc "Contribution source that owns FileTree feature state and sidebar entries."
  @spec source() :: {:extension, :minga_file_tree}
  def source, do: @source

  @doc "Contribution source used for FileTree's dynamically registered input handler."
  @spec input_source() :: {:extension, :minga_file_tree}
  def input_source, do: @input_source

  @doc "Feature-state id used for FileTree UI state."
  @spec feature_id() :: :file_tree
  def feature_id, do: @feature_id

  @doc "Stable sidebar id for FileTree."
  @spec sidebar_id() :: String.t()
  def sidebar_id, do: @sidebar_id

  @doc "Registers FileTree's dynamic input handler and sidebar contribution."
  @spec register_contributions(FileTreeState.t()) :: :ok
  def register_contributions(%FileTreeState{} = file_tree \\ %FileTreeState{}) do
    :ok = Input.register_handler(@input_source, Handler, priority: 50)
    :ok = Scope.register(@source, MingaFileTree.Keymap.Scope)
    ContributionCleanup.register(:keymap_scopes, &Scope.unregister_source/1)
    sync_sidebar(file_tree)
  end

  @doc "Synchronizes the global sidebar contribution from the current FileTree state."
  @spec sync_sidebar(FileTreeState.t() | map()) :: :ok
  def sync_sidebar(%FileTreeState{} = file_tree) do
    status = FileTreeState.status(file_tree)

    with :ok <-
           Sidebar.register(@source, %{
             id: @sidebar_id,
             display_name: "File Tree",
             description: "Project files",
             placement: :left,
             priority: 10,
             preferred_width: FileTreeState.width(file_tree),
             visible?: FileTreeState.visible_status?(status),
             focused?: FileTreeState.focused?(file_tree),
             semantic_kind: "file_tree",
             icon: "folder",
             input_handler: Handler,
             action_handler: {MingaFileTree.Commands, :handle_sidebar_action}
           }) do
      Sidebar.publish_snapshot(@source, @sidebar_id, snapshot(file_tree, status))
    end
  end

  def sync_sidebar(file_tree), do: file_tree |> FileTreeState.coerce() |> sync_sidebar()

  @spec snapshot(FileTreeState.t(), FileTreeState.tree_status()) :: Snapshot.t()
  defp snapshot(%FileTreeState{tree: %FileTree{} = tree} = file_tree, :ready) do
    rows =
      tree
      |> Rows.from_tree(
        active_path: nil,
        dirty_paths: MapSet.new(),
        editing: file_tree.editing,
        focused: FileTreeState.focused?(file_tree),
        git_status: tree.git_status,
        diagnostics: %{},
        selected_index: tree.cursor
      )
      |> Enum.map(&Map.put(&1, :root_path, tree.root))

    Snapshot.new(rows: rows, status: :ready)
  end

  defp snapshot(%FileTreeState{} = file_tree, :hidden) do
    Snapshot.new(rows: root_rows(file_tree), status: :empty, message: nil)
  end

  defp snapshot(%FileTreeState{} = file_tree, :loading) do
    Snapshot.new(rows: root_rows(file_tree), status: :loading, message: "Loading…")
  end

  defp snapshot(%FileTreeState{} = file_tree, :empty) do
    Snapshot.new(rows: root_rows(file_tree), status: :empty, message: "No files")
  end

  defp snapshot(%FileTreeState{} = file_tree, {:error, reason}) do
    Snapshot.new(rows: root_rows(file_tree), status: :error, message: reason)
  end

  @spec root_rows(FileTreeState.t()) :: [map()]
  defp root_rows(%FileTreeState{project_root: root}) when is_binary(root), do: [%{root_path: root}]
  defp root_rows(%FileTreeState{}), do: []
end
