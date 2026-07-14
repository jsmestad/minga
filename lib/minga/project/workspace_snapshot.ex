defmodule Minga.Project.WorkspaceSnapshot do
  @moduledoc """
  Atomic cached state for one active directory workspace.

  The root authorizes recursive project behavior, files are always relative to
  that root, and `rebuilding?` describes discovery for that same root.
  Operational worker, monitor, and timer state remains owned by `Minga.Project`.
  """

  alias Minga.Project.Root

  @enforce_keys [:root, :files, :rebuilding?]
  defstruct [:root, :files, :rebuilding?]

  @typedoc "A coherent directory workspace and its cached inventory state."
  @type t :: %__MODULE__{
          root: Root.t(),
          files: [String.t()],
          rebuilding?: boolean()
        }

  @doc "Installs a directory root with an empty, idle inventory."
  @spec activate(Root.t()) :: t()
  def activate(%Root{kind: :directory} = root) do
    %__MODULE__{root: root, files: [], rebuilding?: false}
  end

  @doc "Clears cached inventory before discovery starts."
  @spec invalidate(t()) :: t()
  def invalidate(%__MODULE__{} = snapshot) do
    %{snapshot | files: [], rebuilding?: false}
  end

  @doc "Marks discovery as running for this workspace."
  @spec begin_rebuild(t()) :: t()
  def begin_rebuild(%__MODULE__{} = snapshot) do
    %{snapshot | rebuilding?: true}
  end

  @doc "Installs one completed workspace-relative inventory atomically."
  @spec complete_rebuild(t(), [String.t()]) :: t()
  def complete_rebuild(%__MODULE__{} = snapshot, files) when is_list(files) do
    %{snapshot | files: files, rebuilding?: false}
  end

  @doc "Marks discovery as stopped while retaining the current cached inventory."
  @spec stop_rebuild(t()) :: t()
  def stop_rebuild(%__MODULE__{} = snapshot) do
    %{snapshot | rebuilding?: false}
  end
end
