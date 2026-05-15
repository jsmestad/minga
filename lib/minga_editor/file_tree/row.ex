defmodule MingaEditor.FileTree.Row do
  @moduledoc """
  Semantic presentation row for file-tree renderers.

  This Layer 2 contract keeps filesystem topology in `Minga.Project.FileTree` while collecting the editor-owned visual state that TUI and GUI renderers need to present the same meaning.
  """

  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.GitStatus
  alias MingaEditor.FileTree.Diagnostics
  alias MingaEditor.State.FileTree, as: FileTreeState

  @type t :: %__MODULE__{
          id: String.t(),
          path: String.t(),
          name: String.t(),
          directory?: boolean(),
          expanded?: boolean(),
          selected?: boolean(),
          focused?: boolean(),
          active?: boolean(),
          dirty?: boolean(),
          git_status: GitStatus.file_status() | nil,
          diagnostics: Diagnostics.t(),
          depth: non_neg_integer(),
          guides: [boolean()],
          last_child?: boolean(),
          editing: FileTreeState.editing() | nil
        }

  @enforce_keys [
    :id,
    :path,
    :name,
    :directory?,
    :expanded?,
    :depth,
    :guides,
    :last_child?
  ]
  defstruct id: nil,
            path: nil,
            name: nil,
            directory?: false,
            expanded?: false,
            selected?: false,
            focused?: false,
            active?: false,
            dirty?: false,
            git_status: nil,
            diagnostics: %Diagnostics{},
            depth: 0,
            guides: [],
            last_child?: false,
            editing: nil

  @doc "Constructs a semantic file-tree row."
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    attrs
    |> Keyword.drop([:relative_path])
    |> then(&struct!(__MODULE__, &1))
  end

  @doc "Builds a stable row identity for a file-tree entry."
  @spec id_for(FileTree.entry()) :: String.t()
  def id_for(%{path: path}), do: Path.expand(path)
end
