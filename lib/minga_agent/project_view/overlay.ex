defmodule MingaAgent.ProjectView.Overlay do
  @moduledoc """
  Overlay-backed project view backend.

  This backend delegates isolation to existing `MingaAgent.Changeset` and uses `MingaAgent.BufferForkStore` only for lifecycle operations when a fork store is provided.
  """

  @behaviour MingaAgent.ProjectView.Backend

  alias MingaAgent.BufferForkStore
  alias MingaAgent.Changeset
  alias MingaAgent.ProjectView

  @type ref :: %{changeset: pid(), fork_store: pid() | nil}

  @doc "Creates an overlay-backed view."
  @spec create(String.t(), keyword()) :: {:ok, ProjectView.t()} | {:error, term()}
  def create(project_root, opts \\ []) when is_binary(project_root) do
    root = Path.expand(project_root)

    with {:ok, changeset} <- Changeset.create(root, Keyword.get(opts, :changeset_opts, [])) do
      ref = %{changeset: changeset, fork_store: Keyword.get(opts, :fork_store)}
      {:ok, ProjectView.new(__MODULE__, root, ref, opts)}
    end
  end

  @impl true
  @spec read_file(ProjectView.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(%ProjectView{} = view, relative_path) do
    Changeset.read_file(changeset(view), relative_path)
  end

  @impl true
  @spec write_file(ProjectView.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write_file(%ProjectView{} = view, relative_path, content) do
    Changeset.write_file(changeset(view), relative_path, content)
  end

  @impl true
  @spec edit_file(ProjectView.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def edit_file(%ProjectView{} = view, relative_path, old_text, new_text) do
    Changeset.edit_file(changeset(view), relative_path, old_text, new_text)
  end

  @impl true
  @spec delete_file(ProjectView.t(), String.t()) :: :ok | {:error, term()}
  def delete_file(%ProjectView{} = view, relative_path) do
    Changeset.delete_file(changeset(view), relative_path)
  end

  @impl true
  @spec list_directory(ProjectView.t(), String.t()) ::
          {:ok, [ProjectView.Backend.directory_entry()]} | {:error, term()}
  def list_directory(%ProjectView{} = view, relative_path) do
    dir = Path.join(working_dir(view), relative_path)

    case File.ls(dir) do
      {:ok, entries} ->
        {:ok, entries |> reject_tombstones() |> Enum.map(&directory_entry(dir, &1))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @spec working_dir(ProjectView.t()) :: String.t()
  def working_dir(%ProjectView{} = view), do: Changeset.overlay_path(changeset(view))

  @impl true
  @spec command_env(ProjectView.t()) :: [{String.t(), String.t()}]
  def command_env(%ProjectView{} = view), do: GenServer.call(changeset(view), :command_env)

  @impl true
  @spec diff(ProjectView.t()) :: {:ok, [map()]} | {:error, term()}
  def diff(%ProjectView{} = view) do
    fork_entries = fork_diff(view)
    changeset_entries = Changeset.summary(changeset(view))
    {:ok, Enum.sort_by(fork_entries ++ changeset_entries, & &1.path)}
  end

  @impl true
  @spec promote(ProjectView.t(), term()) :: :ok | {:conflict, map()} | {:error, term()}
  def promote(%ProjectView{} = view, :project_root) do
    with :ok <- promote_forks(view) do
      Changeset.merge(changeset(view))
    end
  end

  def promote(%ProjectView{project_root: root} = view, target) when is_binary(target) do
    if Path.expand(target) == root do
      promote(view, :project_root)
    else
      {:error, {:unsupported_target, target}}
    end
  end

  def promote(%ProjectView{}, target), do: {:error, {:unsupported_target, target}}

  @impl true
  @spec discard(ProjectView.t()) :: :ok | {:error, term()}
  def discard(%ProjectView{} = view) do
    discard_forks(view)
    Changeset.discard(changeset(view))
  end

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

  @spec changeset(ProjectView.t()) :: pid()
  defp changeset(%ProjectView{ref: %{changeset: changeset}}), do: changeset

  @spec fork_store(ProjectView.t()) :: pid() | nil
  defp fork_store(%ProjectView{ref: %{fork_store: fork_store}}), do: fork_store

  @spec reject_tombstones([String.t()]) :: [String.t()]
  defp reject_tombstones(entries) do
    entries
    |> Enum.reject(fn entry ->
      String.ends_with?(entry, ".__changeset_deleted__") or
        Enum.member?(entries, entry <> ".__changeset_deleted__")
    end)
    |> Enum.sort()
  end

  @spec directory_entry(String.t(), String.t()) :: ProjectView.Backend.directory_entry()
  defp directory_entry(dir, name) do
    type = if File.dir?(Path.join(dir, name)), do: :directory, else: :file
    %{name: name, type: type}
  end

  @spec fork_diff(ProjectView.t()) :: [map()]
  defp fork_diff(%ProjectView{} = view) do
    case fork_store(view) do
      nil ->
        []

      store ->
        store
        |> BufferForkStore.all()
        |> Map.keys()
        |> Enum.map(&%{path: Path.relative_to(&1, view.project_root), kind: :modified})
    end
  catch
    :exit, _ -> []
  end

  @spec promote_forks(ProjectView.t()) :: :ok | {:conflict, map()}
  defp promote_forks(%ProjectView{} = view) do
    case fork_store(view) do
      nil ->
        :ok

      store ->
        store
        |> BufferForkStore.merge_all_keep_failed()
        |> fork_merge_result()
    end
  catch
    :exit, reason -> {:conflict, %{conflicts: [{:exit, reason}], results: []}}
  end

  @spec fork_merge_result([{String.t(), :ok | {:conflict, term()} | {:error, term()}}]) ::
          :ok | {:conflict, map()}
  defp fork_merge_result(results) do
    failures = Enum.reject(results, &match?({_path, :ok}, &1))
    if failures == [], do: :ok, else: {:conflict, %{conflicts: failures, results: results}}
  end

  @spec discard_forks(ProjectView.t()) :: :ok
  defp discard_forks(%ProjectView{} = view) do
    case fork_store(view) do
      nil -> :ok
      store -> BufferForkStore.discard_all(store)
    end
  catch
    :exit, _ -> :ok
  end
end
