defmodule MingaAgent.ProjectView.RecordingBackend do
  @moduledoc false

  @behaviour MingaAgent.ProjectView.Backend

  alias MingaAgent.ProjectView

  @type ref :: %{
          parent: pid(),
          working_dir: String.t(),
          env: [{String.t(), String.t()}]
        }

  @spec create(String.t(), keyword()) :: {:ok, ProjectView.t()}
  def create(project_root, opts) do
    working_dir = Keyword.fetch!(opts, :working_dir)
    File.mkdir_p!(working_dir)

    ref = %{
      parent: Keyword.fetch!(opts, :parent),
      working_dir: working_dir,
      env: Keyword.get(opts, :env, [])
    }

    {:ok, ProjectView.new(__MODULE__, project_root, ref, opts)}
  end

  @impl true
  @spec read_file(ProjectView.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(%ProjectView{} = view, relative_path) do
    record(view, {:read_file, relative_path})
    File.read(Path.join(working_dir_path(view), relative_path))
  end

  @impl true
  @spec write_file(ProjectView.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write_file(%ProjectView{} = view, relative_path, content) do
    record(view, {:write_file, relative_path, content})
    path = Path.join(working_dir_path(view), relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write(path, content)
  end

  @impl true
  @spec edit_file(ProjectView.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def edit_file(%ProjectView{} = view, relative_path, old_text, new_text) do
    record(view, {:edit_file, relative_path, old_text, new_text})
    path = Path.join(working_dir_path(view), relative_path)

    with {:ok, content} <- File.read(path) do
      File.write(path, String.replace(content, old_text, new_text, global: false))
    end
  end

  @impl true
  @spec delete_file(ProjectView.t(), String.t()) :: :ok | {:error, term()}
  def delete_file(%ProjectView{} = view, relative_path) do
    record(view, {:delete_file, relative_path})
    File.rm(Path.join(working_dir_path(view), relative_path))
  end

  @impl true
  @spec list_directory(ProjectView.t(), String.t()) ::
          {:ok, [ProjectView.Backend.directory_entry()]} | {:error, term()}
  def list_directory(%ProjectView{} = view, relative_path) do
    record(view, {:list_directory, relative_path})
    path = Path.join(working_dir_path(view), relative_path)

    case File.ls(path) do
      {:ok, entries} -> {:ok, Enum.map(entries, &directory_entry(path, &1))}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec working_dir(ProjectView.t()) :: String.t()
  def working_dir(%ProjectView{} = view) do
    record(view, :working_dir)
    view.ref.working_dir
  end

  @impl true
  @spec command_env(ProjectView.t()) :: [{String.t(), String.t()}]
  def command_env(%ProjectView{} = view) do
    record(view, :command_env)
    view.ref.env
  end

  @impl true
  @spec diff(ProjectView.t()) :: {:ok, [map()]} | {:error, term()}
  def diff(%ProjectView{} = view) do
    record(view, :diff)
    {:ok, []}
  end

  @impl true
  @spec promote(ProjectView.t(), term()) :: :ok | {:error, term()}
  def promote(%ProjectView{} = view, target) do
    record(view, {:promote, target})
    :ok
  end

  @impl true
  @spec discard_file(ProjectView.t(), String.t()) :: :ok | {:error, term()}
  def discard_file(%ProjectView{} = view, relative_path) do
    record(view, {:discard_file, relative_path})
    :ok
  end

  @impl true
  @spec discard(ProjectView.t()) :: :ok | {:error, term()}
  def discard(%ProjectView{} = view) do
    record(view, :discard)
    :ok
  end

  @impl true
  @spec capabilities(ProjectView.t()) :: ProjectView.Backend.capabilities()
  def capabilities(%ProjectView{} = view) do
    record(view, :capabilities)

    %{
      isolation: :recording,
      mutates_project_root: false,
      supports_promote: true,
      supports_discard: true,
      supports_command_env: true
    }
  end

  @spec working_dir_path(ProjectView.t()) :: String.t()
  defp working_dir_path(%ProjectView{} = view), do: view.ref.working_dir

  @spec directory_entry(String.t(), String.t()) :: ProjectView.Backend.directory_entry()
  defp directory_entry(path, name) do
    type = if File.dir?(Path.join(path, name)), do: :directory, else: :file
    %{name: name, type: type}
  end

  @spec record(ProjectView.t(), term()) :: :ok
  defp record(%ProjectView{ref: %{parent: parent}}, message) do
    send(parent, {:project_view_call, message})
    :ok
  end
end
