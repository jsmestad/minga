defmodule MingaAgent.ProjectView.Backend do
  @moduledoc """
  Behaviour for workspace project view backends.

  Backends implement file access for one workspace-local view. Callers use `MingaAgent.ProjectView`; backend modules stay hidden behind the facade.
  """

  alias MingaAgent.ProjectView

  @typedoc "Backend-owned reference, usually a pid or small state map."
  @type ref :: term()

  @typedoc "Directory listing entry."
  @type directory_entry :: %{name: String.t(), type: :file | :directory}

  @typedoc "Backend capability flags."
  @type capabilities :: %{
          isolation: :none | :overlay,
          mutates_project_root: boolean(),
          supports_promote: boolean(),
          supports_discard: boolean(),
          supports_command_env: boolean()
        }

  @callback read_file(ProjectView.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  @callback write_file(ProjectView.t(), String.t(), binary()) :: :ok | {:error, term()}
  @callback edit_file(ProjectView.t(), String.t(), String.t(), String.t()) ::
              :ok | {:error, term()}
  @callback delete_file(ProjectView.t(), String.t()) :: :ok | {:error, term()}
  @callback list_directory(ProjectView.t(), String.t()) ::
              {:ok, [directory_entry()]} | {:error, term()}
  @callback working_dir(ProjectView.t()) :: String.t()
  @callback command_env(ProjectView.t()) :: [{String.t(), String.t()}]
  @callback diff(ProjectView.t()) :: {:ok, [map()]} | {:error, term()}
  @callback promote(ProjectView.t(), term()) :: :ok | {:conflict, map()} | {:error, term()}
  @callback discard_file(ProjectView.t(), String.t()) :: :ok | {:error, term()}
  @callback discard(ProjectView.t()) :: :ok | {:error, term()}
  @callback capabilities(ProjectView.t()) :: capabilities()
end
