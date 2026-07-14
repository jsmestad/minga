defmodule MingaEditor.FileTree.ProjectCache.Snapshot do
  @moduledoc "Immutable project-cache data prepared outside file-tree value transitions."

  @enforce_keys [:root, :active?, :files, :rebuilding?]
  defstruct [:root, :active?, :files, :rebuilding?]

  @type t :: %__MODULE__{
          root: String.t(),
          active?: boolean(),
          files: [String.t()],
          rebuilding?: boolean()
        }

  @doc "Builds a project-cache snapshot for one expanded tree root."
  @spec new(String.t(), boolean(), [String.t()], boolean()) :: t()
  def new(root, active?, files, rebuilding?)
      when is_binary(root) and is_boolean(active?) and is_list(files) and
             is_boolean(rebuilding?) do
    %__MODULE__{
      root: Path.expand(root),
      active?: active?,
      files: files,
      rebuilding?: rebuilding?
    }
  end
end
