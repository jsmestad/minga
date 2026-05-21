defmodule MingaAgent.ProjectView.UnavailableBackend do
  @moduledoc false

  @behaviour MingaAgent.ProjectView.Backend

  alias MingaAgent.ProjectView

  @spec create(String.t(), keyword()) :: {:ok, ProjectView.t()}
  def create(project_root, opts) do
    {:ok, ProjectView.new(__MODULE__, project_root, %{ref: self()}, opts)}
  end

  @impl true
  @spec read_file(ProjectView.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(%ProjectView{}, _relative_path), do: {:error, :read_failed}

  @impl true
  @spec write_file(ProjectView.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write_file(%ProjectView{}, _relative_path, _content), do: {:error, :write_failed}

  @impl true
  @spec edit_file(ProjectView.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def edit_file(%ProjectView{}, _relative_path, _old_text, _new_text), do: {:error, :edit_failed}

  @impl true
  @spec delete_file(ProjectView.t(), String.t()) :: :ok | {:error, term()}
  def delete_file(%ProjectView{}, _relative_path), do: {:error, :delete_failed}

  @impl true
  @spec list_directory(ProjectView.t(), String.t()) ::
          {:ok, [ProjectView.Backend.directory_entry()]} | {:error, term()}
  def list_directory(%ProjectView{}, _relative_path), do: {:error, :list_failed}

  @impl true
  @spec working_dir(ProjectView.t()) :: String.t() | {:error, term()}
  def working_dir(%ProjectView{}), do: {:error, :working_dir_failed}

  @impl true
  @spec command_env(ProjectView.t()) :: [{String.t(), String.t()}] | {:error, term()}
  def command_env(%ProjectView{}), do: {:error, :command_env_failed}

  @impl true
  @spec diff(ProjectView.t()) :: {:ok, [map()]} | {:error, term()}
  def diff(%ProjectView{}), do: {:error, :diff_failed}

  @impl true
  @spec promote(ProjectView.t(), term()) :: :ok | {:conflict, map()} | {:error, term()}
  def promote(%ProjectView{}, :project_root), do: {:error, :promote_failed}
  def promote(%ProjectView{}, target), do: {:error, {:unsupported_target, target}}

  @impl true
  @spec discard_file(ProjectView.t(), String.t()) :: :ok | {:error, term()}
  def discard_file(%ProjectView{}, _relative_path), do: {:error, :discard_file_failed}

  @impl true
  @spec discard(ProjectView.t()) :: :ok | {:error, term()}
  def discard(%ProjectView{}), do: {:error, :discard_failed}

  @impl true
  @spec close(ProjectView.t()) :: :ok | {:error, term()}
  def close(%ProjectView{}), do: {:error, :close_failed}

  @impl true
  @spec capabilities(ProjectView.t()) :: ProjectView.Backend.capabilities()
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
