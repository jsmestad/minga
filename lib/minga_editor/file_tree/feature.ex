defmodule MingaEditor.FileTree.Feature do
  @moduledoc """
  FileTree feature ownership adapter.

  FileTree is still implemented in core, but its UI state, input handler, and sidebar contribution are registered through the same source-owned paths that a bundled extension will use after extraction.
  """

  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Input
  alias MingaEditor.Input.FileTreeHandler
  alias MingaEditor.State.FileTree, as: FileTreeState

  @source :builtin
  @input_source :builtin
  @feature_id :file_tree
  @sidebar_id "file_tree"

  @doc "Contribution source used while FileTree remains a bundled core feature."
  @spec source() :: :builtin
  def source, do: @source

  @doc "Contribution source used for FileTree's dynamically registered input handler."
  @spec input_source() :: :builtin
  def input_source, do: @input_source

  @doc "Feature-state id used for FileTree UI state."
  @spec feature_id() :: :file_tree
  def feature_id, do: @feature_id

  @doc "Stable sidebar id for FileTree."
  @spec sidebar_id() :: String.t()
  def sidebar_id, do: @sidebar_id

  @doc "Registers FileTree's dynamic input handler and sidebar contribution."
  @spec register_contributions(FileTreeState.t()) :: :ok | {:error, term()}
  def register_contributions(%FileTreeState{} = file_tree \\ %FileTreeState{}) do
    :ok = Input.register_handler(@input_source, FileTreeHandler, priority: 50)
    sync_sidebar(file_tree)
  end

  @doc "Synchronizes the global sidebar contribution from the current FileTree state."
  @spec sync_sidebar(FileTreeState.t()) :: :ok | {:error, term()}
  def sync_sidebar(%FileTreeState{} = file_tree) do
    status = FileTreeState.status(file_tree)

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
      input_handler: FileTreeHandler,
      action_handler: {MingaEditor.Commands.FileTree, :handle_sidebar_action}
    })
  end
end
