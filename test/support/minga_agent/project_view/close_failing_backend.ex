defmodule MingaAgent.Test.ProjectView.CloseFailingBackend do
  @moduledoc false

  @behaviour MingaAgent.ProjectView.Backend

  alias MingaAgent.ProjectView

  @impl true
  @spec read_file(ProjectView.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(%ProjectView{}, _relative_path), do: {:ok, ""}

  @impl true
  @spec write_file(ProjectView.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write_file(%ProjectView{}, _relative_path, _content), do: :ok

  @impl true
  @spec edit_file(ProjectView.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def edit_file(%ProjectView{}, _relative_path, _old_text, _new_text), do: :ok

  @impl true
  @spec delete_file(ProjectView.t(), String.t()) :: :ok | {:error, term()}
  def delete_file(%ProjectView{}, _relative_path), do: :ok

  @impl true
  @spec list_directory(ProjectView.t(), String.t()) ::
          {:ok, [MingaAgent.ProjectView.Backend.directory_entry()]} | {:error, term()}
  def list_directory(%ProjectView{}, _relative_path), do: {:ok, []}

  @impl true
  @spec working_dir(ProjectView.t()) :: String.t()
  def working_dir(%ProjectView{project_root: project_root}), do: project_root

  @impl true
  @spec command_env(ProjectView.t()) :: [{String.t(), String.t()}]
  def command_env(%ProjectView{}), do: []

  @impl true
  @spec diff(ProjectView.t()) :: {:ok, [map()]}
  def diff(%ProjectView{}), do: {:ok, []}

  @impl true
  @spec promote(ProjectView.t(), term()) :: :ok | {:conflict, map()} | {:error, term()}
  def promote(%ProjectView{}, :project_root), do: :ok
  def promote(%ProjectView{}, target), do: {:error, {:unsupported_target, target}}

  @impl true
  @spec discard_file(ProjectView.t(), String.t()) :: :ok | {:error, term()}
  def discard_file(%ProjectView{}, _relative_path), do: :ok

  @impl true
  @spec discard(ProjectView.t()) :: :ok | {:error, term()}
  def discard(%ProjectView{}), do: :ok

  @impl true
  @spec close(ProjectView.t()) :: :ok | {:error, term()}
  def close(%ProjectView{} = view) do
    send(view.ref, {:project_view_close_called, view.project_root})
    {:error, :close_failed}
  end

  @impl true
  @spec capabilities(ProjectView.t()) :: MingaAgent.ProjectView.Backend.capabilities()
  def capabilities(%ProjectView{}) do
    %{
      isolation: :overlay,
      mutates_project_root: false,
      supports_promote: true,
      supports_discard: true,
      supports_command_env: true
    }
  end
end
