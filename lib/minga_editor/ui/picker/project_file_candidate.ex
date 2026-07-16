defmodule MingaEditor.UI.Picker.ProjectFileCandidate do
  @moduledoc """
  Captured identity for one project file picker choice.

  The authorized project root and workspace-relative cached path travel together
  from candidate production through preview and selection. Resolving the value
  always re-enters the `Minga.Project.Root` authorization boundary and never
  consults the active Project or file tree.
  """

  alias Minga.Project.Root

  @enforce_keys [:root, :path]
  defstruct [:root, :path]

  @typedoc "A project file choice tied to the workspace that produced it."
  @type t :: %__MODULE__{root: Root.t(), path: String.t()}

  @typedoc "Why a project file candidate could not be constructed or resolved."
  @type error :: Root.file_error() | :empty_path

  @doc "Builds a candidate from an authorized directory root and a workspace-relative path."
  @spec new(Root.t(), String.t()) :: {:ok, t()} | {:error, error()}
  def new(%Root{kind: :directory} = root, path) when is_binary(path) do
    case Path.type(path) do
      :relative -> safe_candidate(root, Path.safe_relative(path))
      _absolute_or_volume_relative -> {:error, :absolute_path}
    end
  end

  def new(%Root{}, path) when is_binary(path), do: {:error, :not_a_directory_root}

  @doc "Resolves the candidate through its captured authorized root."
  @spec resolve(t()) :: {:ok, String.t()} | {:error, error()}
  def resolve(%__MODULE__{root: %Root{} = root, path: path}) do
    Root.resolve_file(root, path)
  end

  @doc """
  Authorizes the candidate and returns its lexical workspace entry path.

  This is for entry-level operations such as unlinking a symlink: authorization
  follows the target through `Root`, while the returned path still names the
  selected directory entry rather than its canonical referent.
  """
  @spec authorized_entry_path(t()) :: {:ok, String.t()} | {:error, error()}
  def authorized_entry_path(%__MODULE__{root: %Root{} = root, path: path} = candidate) do
    with {:ok, _canonical_path} <- resolve(candidate) do
      {:ok, Path.join(root.path, path)}
    end
  end

  @spec safe_candidate(Root.t(), {:ok, String.t()} | :error) ::
          {:ok, t()} | {:error, :empty_path | :parent_traversal}
  defp safe_candidate(_root, {:ok, ""}), do: {:error, :empty_path}
  defp safe_candidate(root, {:ok, path}), do: {:ok, %__MODULE__{root: root, path: path}}
  defp safe_candidate(_root, :error), do: {:error, :parent_traversal}
end
