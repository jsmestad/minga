defmodule MingaEditor.UI.Picker.FindFileSession do
  @moduledoc """
  Immutable anchors captured when the general file finder opens.

  The launch and Home directories never follow later process or project changes. A project-backed
  finder also retains the exact project root needed to restore ordinary fuzzy search after the user
  removes an explicit filesystem path.
  """

  alias Minga.Project.Root
  alias Minga.Project.WorkspaceSnapshot

  @enforce_keys [:launch_directory, :home_directory]
  defstruct [:launch_directory, :home_directory, :project_root, :project_activation_id]

  @type t :: %__MODULE__{
          launch_directory: String.t(),
          home_directory: String.t(),
          project_root: Root.t() | nil,
          project_activation_id: WorkspaceSnapshot.activation_id() | nil
        }

  @doc "Builds one finder session from captured absolute directory anchors."
  @spec new(String.t(), String.t(), WorkspaceSnapshot.t() | nil) :: t()
  def new(launch_directory, home_directory, workspace)
      when is_binary(launch_directory) and is_binary(home_directory) do
    {project_root, project_activation_id} = project_identity(workspace)

    %__MODULE__{
      launch_directory: Path.expand(launch_directory),
      home_directory: Path.expand(home_directory),
      project_root: project_root,
      project_activation_id: project_activation_id
    }
  end

  @doc "Returns the original FileSource context for a project-backed general finder."
  @spec project_context(t()) :: map() | nil
  def project_context(%__MODULE__{project_root: nil}), do: nil

  def project_context(
        %__MODULE__{project_root: %Root{} = root, project_activation_id: activation_id} = session
      ) do
    %{
      project_root: root,
      project_activation_id: activation_id,
      find_file_session: session
    }
  end

  @doc "Returns whether removing filesystem intent should restore project fuzzy search."
  @spec project_backed?(t()) :: boolean()
  def project_backed?(%__MODULE__{project_root: %Root{}}), do: true
  def project_backed?(%__MODULE__{}), do: false

  @spec project_identity(WorkspaceSnapshot.t() | nil) ::
          {Root.t() | nil, WorkspaceSnapshot.activation_id() | nil}
  defp project_identity(nil), do: {nil, nil}

  defp project_identity(%WorkspaceSnapshot{root: root, activation_id: activation_id}),
    do: {root, activation_id}
end
