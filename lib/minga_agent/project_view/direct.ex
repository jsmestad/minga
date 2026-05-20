defmodule MingaAgent.ProjectView.Direct do
  @moduledoc """
  Direct project view backend.

  Reads and writes files directly under the project root. The backend keeps a small in-memory operation index so `diff/1` and `discard/1` have the same shape as overlay-backed views, but direct writes intentionally mutate the project root immediately.
  """

  @behaviour MingaAgent.ProjectView.Backend

  alias MingaAgent.ProjectView
  alias MingaAgent.ProjectView.PathResolver

  @type direct_state :: %{modified: MapSet.t(String.t()), deleted: MapSet.t(String.t())}

  @doc "Creates a direct backend view."
  @spec create(String.t(), keyword()) :: {:ok, ProjectView.t()} | {:error, term()}
  def create(project_root, opts \\ []) when is_binary(project_root) do
    root = Path.expand(project_root)

    if File.dir?(root) do
      {:ok, ref} = Agent.start_link(fn -> %{modified: MapSet.new(), deleted: MapSet.new()} end)
      {:ok, ProjectView.new(__MODULE__, root, ref, opts)}
    else
      {:error, {:not_a_directory, root}}
    end
  end

  @impl true
  @spec read_file(ProjectView.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(%ProjectView{} = view, relative_path) do
    with {:ok, target} <- safe_target(view, relative_path) do
      File.read(target)
    end
  end

  @impl true
  @spec write_file(ProjectView.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write_file(%ProjectView{} = view, relative_path, content) do
    with {:ok, target} <- safe_target(view, relative_path),
         :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.write(target, content) do
      track_modified(view, relative_path)
    end
  end

  @impl true
  @spec edit_file(ProjectView.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def edit_file(%ProjectView{} = view, relative_path, old_text, new_text) do
    with {:ok, content} <- read_file(view, relative_path),
         {:ok, edited} <- replace_exact(content, old_text, new_text) do
      write_file(view, relative_path, edited)
    end
  end

  @impl true
  @spec delete_file(ProjectView.t(), String.t()) :: :ok | {:error, term()}
  def delete_file(%ProjectView{} = view, relative_path) do
    with {:ok, target} <- safe_target(view, relative_path),
         :ok <- File.rm(target) do
      track_deleted(view, relative_path)
    end
  end

  @impl true
  @spec list_directory(ProjectView.t(), String.t()) ::
          {:ok, [ProjectView.Backend.directory_entry()]} | {:error, term()}
  def list_directory(%ProjectView{} = view, relative_path) do
    with {:ok, dir} <- safe_target(view, relative_path, allow_root: true) do
      case File.ls(dir) do
        {:ok, entries} -> {:ok, Enum.map(Enum.sort(entries), &directory_entry(dir, &1))}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  @spec working_dir(ProjectView.t()) :: String.t()
  def working_dir(%ProjectView{project_root: project_root}), do: project_root

  @impl true
  @spec command_env(ProjectView.t()) :: [{String.t(), String.t()}]
  def command_env(%ProjectView{}), do: []

  @impl true
  @spec diff(ProjectView.t()) :: {:ok, [map()]} | {:error, term()}
  def diff(%ProjectView{} = view) do
    state = Agent.get(view.ref, & &1)

    modified =
      state.modified
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.map(&%{path: &1, kind: :modified})

    deleted =
      state.deleted
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.map(&%{path: &1, kind: :deleted})

    {:ok, modified ++ deleted}
  end

  @impl true
  @spec promote(ProjectView.t(), term()) :: :ok | {:error, term()}
  def promote(%ProjectView{}, :project_root), do: :ok

  def promote(%ProjectView{project_root: root}, target) when is_binary(target) do
    if Path.expand(target) == root, do: :ok, else: {:error, {:unsupported_target, target}}
  end

  def promote(%ProjectView{}, target), do: {:error, {:unsupported_target, target}}

  @impl true
  @spec discard(ProjectView.t()) :: :ok | {:error, term()}
  def discard(%ProjectView{} = view) do
    Agent.update(view.ref, fn _ -> %{modified: MapSet.new(), deleted: MapSet.new()} end)
  catch
    :exit, _ -> :ok
  end

  @impl true
  @spec capabilities(ProjectView.t()) :: ProjectView.Backend.capabilities()
  def capabilities(%ProjectView{}) do
    %{
      isolation: :none,
      mutates_project_root: true,
      supports_promote: false,
      supports_discard: false,
      supports_command_env: false
    }
  end

  @spec safe_target(ProjectView.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_traversal | :symlink_traversal}
  defp safe_target(%ProjectView{project_root: project_root}, relative_path, opts \\ []) do
    PathResolver.resolve(project_root, relative_path, opts)
  end

  @spec replace_exact(binary(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, :old_text_not_found}
  defp replace_exact(content, old_text, new_text) do
    if String.contains?(content, old_text) do
      {:ok, String.replace(content, old_text, new_text, global: false)}
    else
      {:error, :old_text_not_found}
    end
  end

  @spec directory_entry(String.t(), String.t()) :: ProjectView.Backend.directory_entry()
  defp directory_entry(dir, name) do
    type = if File.dir?(Path.join(dir, name)), do: :directory, else: :file
    %{name: name, type: type}
  end

  @spec track_modified(ProjectView.t(), String.t()) :: :ok
  defp track_modified(%ProjectView{} = view, relative_path) do
    Agent.update(view.ref, fn state ->
      state
      |> Map.update!(:modified, &MapSet.put(&1, relative_path))
      |> Map.update!(:deleted, &MapSet.delete(&1, relative_path))
    end)
  end

  @spec track_deleted(ProjectView.t(), String.t()) :: :ok
  defp track_deleted(%ProjectView{} = view, relative_path) do
    Agent.update(view.ref, fn state ->
      state
      |> Map.update!(:modified, &MapSet.delete(&1, relative_path))
      |> Map.update!(:deleted, &MapSet.put(&1, relative_path))
    end)
  end
end
