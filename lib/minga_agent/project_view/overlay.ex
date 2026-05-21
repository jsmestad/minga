# credo:disable-for-this-file Credo.Check.Readability.PreferImplicitTry
# credo:disable-for-this-file Credo.Check.Refactor.Nesting

defmodule MingaAgent.ProjectView.Overlay do
  @moduledoc """
  Overlay-backed project view backend.

  This backend delegates isolation to existing `MingaAgent.Changeset` and uses `MingaAgent.BufferForkStore` only for lifecycle operations when a fork store is provided.
  """

  @behaviour MingaAgent.ProjectView.Backend

  alias MingaAgent.BufferForkStore
  alias MingaAgent.Changeset
  alias MingaAgent.ProjectView

  @type ref :: %{changeset: pid(), fork_store: pid() | nil, owned_fork_store?: boolean()}

  @doc "Creates an overlay-backed view."
  @spec create(String.t(), keyword()) :: {:ok, ProjectView.t()} | {:error, term()}
  def create(project_root, opts \\ []) when is_binary(project_root) do
    root = Path.expand(project_root)

    case ensure_fork_store(Keyword.get(opts, :fork_store)) do
      {:ok, fork_store, owned_fork_store?} ->
        case Changeset.create(root, Keyword.get(opts, :changeset_opts, [])) do
          {:ok, changeset} ->
            ref = %{
              changeset: changeset,
              fork_store: fork_store,
              owned_fork_store?: owned_fork_store?
            }

            {:ok, ProjectView.new(__MODULE__, root, ref, opts)}

          {:error, reason} ->
            maybe_stop_fork_store(fork_store, owned_fork_store?)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @spec read_file(ProjectView.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(%ProjectView{} = view, relative_path) do
    case read_open_buffer(view, relative_path) do
      {:ok, content} ->
        {:ok, content}

      :changeset ->
        safe_changeset_call(fn -> Changeset.read_file(changeset(view), relative_path) end)

      {:error, _} = error ->
        error
    end
  end

  @impl true
  @spec write_file(ProjectView.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write_file(%ProjectView{} = view, relative_path, content) do
    case write_open_buffer(view, relative_path, content) do
      :forked ->
        :ok

      :changeset ->
        safe_changeset_call(fn ->
          Changeset.write_file(changeset(view), relative_path, content)
        end)

      {:error, _} = error ->
        error
    end
  end

  @impl true
  @spec edit_file(ProjectView.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def edit_file(%ProjectView{} = view, relative_path, old_text, new_text) do
    case edit_open_buffer(view, relative_path, old_text, new_text) do
      :forked ->
        :ok

      :changeset ->
        safe_changeset_call(fn ->
          Changeset.edit_file(changeset(view), relative_path, old_text, new_text)
        end)

      {:error, _} = error ->
        error
    end
  end

  @spec read_open_buffer(ProjectView.t(), String.t()) ::
          {:ok, binary()} | :changeset | {:error, term()}
  defp read_open_buffer(%ProjectView{} = view, relative_path) do
    case open_buffer_pid(view, relative_path) do
      {:ok, buf_pid} ->
        case fork_store(view) do
          nil -> {:ok, Minga.Buffer.content(buf_pid)}
          fork_store -> read_fork_or_buffer(fork_store, buffer_path(view, relative_path), buf_pid)
        end

      :not_found ->
        :changeset

      {:error, _} = error ->
        error
    end
  end

  @spec write_open_buffer(ProjectView.t(), String.t(), binary()) ::
          :forked | :changeset | {:error, term()}
  defp write_open_buffer(%ProjectView{} = view, relative_path, content) do
    case open_buffer_pid(view, relative_path) do
      {:ok, buf_pid} ->
        case fork_store(view) do
          nil -> :changeset
          fork_store -> write_fork(fork_store, buffer_path(view, relative_path), buf_pid, content)
        end

      :not_found ->
        :changeset

      {:error, _} = error ->
        error
    end
  end

  @spec edit_open_buffer(ProjectView.t(), String.t(), String.t(), String.t()) ::
          :forked | :changeset | {:error, term()}
  defp edit_open_buffer(%ProjectView{} = view, relative_path, old_text, new_text) do
    case open_buffer_pid(view, relative_path) do
      {:ok, buf_pid} ->
        case fork_store(view) do
          nil ->
            :changeset

          fork_store ->
            edit_fork(fork_store, buffer_path(view, relative_path), buf_pid, old_text, new_text)
        end

      :not_found ->
        :changeset

      {:error, _} = error ->
        error
    end
  end

  @spec open_buffer_pid(ProjectView.t(), String.t()) ::
          {:ok, pid()} | :not_found | {:error, term()}
  defp open_buffer_pid(%ProjectView{} = view, relative_path) do
    case Minga.Buffer.pid_for_path(buffer_path(view, relative_path)) do
      {:ok, buf_pid} -> {:ok, buf_pid}
      :not_found -> :not_found
    end
  rescue
    _ -> {:error, {:buffer_lookup_failed, relative_path}}
  end

  @spec read_fork_or_buffer(pid(), String.t(), pid()) ::
          {:ok, binary()} | :changeset | {:error, term()}
  defp read_fork_or_buffer(fork_store, path, buf_pid) do
    with :ok <- fork_store_available(fork_store) do
      case BufferForkStore.get(fork_store, path) do
        nil ->
          case safe_buffer_content(buf_pid) do
            {:ok, content} -> {:ok, content}
            {:error, _} -> :changeset
          end

        fork_pid ->
          {:ok, Minga.Buffer.Fork.content(fork_pid)}
      end
    end
  end

  @spec write_fork(pid(), String.t(), pid(), binary()) :: :forked | {:error, term()}
  defp write_fork(fork_store, path, buf_pid, content) do
    with :ok <- fork_store_available(fork_store),
         {:ok, fork_pid} <- BufferForkStore.get_or_create(fork_store, path, buf_pid) do
      Minga.Buffer.Fork.replace_content(fork_pid, content)
      :forked
    end
  catch
    :exit, reason -> {:error, {:fork_unavailable, reason}}
  end

  @spec edit_fork(pid(), String.t(), pid(), String.t(), String.t()) :: :forked | {:error, term()}
  defp edit_fork(fork_store, path, buf_pid, old_text, new_text) do
    with :ok <- fork_store_available(fork_store),
         {:ok, fork_pid} <- BufferForkStore.get_or_create(fork_store, path, buf_pid) do
      case Minga.Buffer.Fork.find_and_replace(fork_pid, old_text, new_text) do
        {:ok, _msg} -> :forked
        {:error, _} = error -> error
      end
    end
  catch
    :exit, reason -> {:error, {:fork_unavailable, reason}}
  end

  @spec buffer_path(ProjectView.t(), String.t()) :: String.t()
  defp buffer_path(%ProjectView{} = view, relative_path) do
    Path.join(view.project_root, relative_path)
  end

  @spec safe_buffer_content(pid()) :: {:ok, binary()} | {:error, term()}
  defp safe_buffer_content(buf_pid) do
    try do
      {:ok, Minga.Buffer.content(buf_pid)}
    catch
      :exit, reason -> {:error, {:buffer_unavailable, reason}}
    end
  end

  @spec ensure_fork_store(pid() | nil) :: {:ok, pid(), boolean()} | {:error, term()}
  defp ensure_fork_store(nil) do
    case GenServer.start(BufferForkStore, :ok) do
      {:ok, fork_store} -> {:ok, fork_store, true}
      {:error, reason} -> {:error, {:fork_store_failed, reason}}
    end
  end

  defp ensure_fork_store(fork_store) when is_pid(fork_store), do: {:ok, fork_store, false}

  @spec maybe_stop_fork_store(pid() | nil, boolean()) :: :ok
  defp maybe_stop_fork_store(fork_store, true) when is_pid(fork_store) do
    BufferForkStore.stop(fork_store)
  catch
    :exit, _ -> :ok
  end

  defp maybe_stop_fork_store(_fork_store, _owned?), do: :ok

  @impl true
  @spec delete_file(ProjectView.t(), String.t()) :: :ok | {:error, term()}
  def delete_file(%ProjectView{} = view, relative_path) do
    safe_changeset_call(fn -> Changeset.delete_file(changeset(view), relative_path) end)
  end

  @impl true
  @spec list_directory(ProjectView.t(), String.t()) ::
          {:ok, [ProjectView.Backend.directory_entry()]} | {:error, term()}
  def list_directory(%ProjectView{} = view, relative_path) do
    case working_dir(view) do
      {:error, _} = error ->
        error

      dir ->
        case File.ls(Path.join(dir, relative_path)) do
          {:ok, entries} ->
            {:ok,
             entries
             |> reject_tombstones()
             |> Enum.map(&directory_entry(Path.join(dir, relative_path), &1))}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl true
  @spec working_dir(ProjectView.t()) :: String.t() | {:error, term()}
  def working_dir(%ProjectView{} = view),
    do: safe_changeset_call(fn -> Changeset.overlay_path(changeset(view)) end)

  @impl true
  @spec command_env(ProjectView.t()) :: [{String.t(), String.t()}] | {:error, term()}
  def command_env(%ProjectView{} = view),
    do: safe_changeset_call(fn -> GenServer.call(changeset(view), :command_env) end)

  @impl true
  @spec diff(ProjectView.t()) :: {:ok, [map()]} | {:error, term()}
  def diff(%ProjectView{} = view) do
    with {:ok, fork_entries} <- fork_diff(view) do
      case safe_changeset_call(fn -> Changeset.summary(changeset(view)) end) do
        {:error, reason} -> {:error, reason}
        changeset_entries -> {:ok, Enum.sort_by(fork_entries ++ changeset_entries, & &1.path)}
      end
    end
  end

  @impl true
  @spec promote(ProjectView.t(), term()) :: :ok | {:conflict, map()} | {:error, term()}
  def promote(%ProjectView{} = view, :project_root) do
    with :ok <- ensure_changeset_available(view),
         :ok <- promote_forks(view) do
      safe_changeset_call(fn -> Changeset.merge(changeset(view)) end)
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
  @spec discard_file(ProjectView.t(), String.t()) :: :ok | {:error, term()}
  def discard_file(%ProjectView{} = view, relative_path) do
    with :ok <- ensure_changeset_available(view),
         :ok <- discard_fork(view, relative_path) do
      safe_changeset_call(fn -> Changeset.discard_file(changeset(view), relative_path) end)
    end
  end

  @impl true
  @spec discard(ProjectView.t()) :: :ok | {:error, term()}
  def discard(%ProjectView{} = view) do
    with :ok <- ensure_changeset_available(view),
         :ok <- discard_forks(view) do
      safe_changeset_call(fn -> Changeset.discard(changeset(view)) end)
    end
  end

  @impl true
  @spec close(ProjectView.t()) :: :ok | {:error, term()}
  def close(%ProjectView{} = view) do
    with :ok <- ensure_closeable(view) do
      maybe_stop_changeset(view)
      maybe_stop_fork_store(fork_store(view), owned_fork_store?(view))
      :ok
    end
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

  @spec ensure_changeset_available(ProjectView.t()) :: :ok | {:error, term()}
  defp ensure_changeset_available(%ProjectView{} = view) do
    case working_dir(view) do
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  @spec ensure_closeable(ProjectView.t()) :: :ok | {:error, term()}
  defp ensure_closeable(%ProjectView{} = view) do
    if changeset_dirty?(view) do
      {:error, {:close_blocked, :changeset_dirty}}
    else
      if owned_fork_store_dirty?(view) do
        {:error, {:close_blocked, :fork_store_dirty}}
      else
        :ok
      end
    end
  end

  @spec changeset_dirty?(ProjectView.t()) :: boolean()
  defp changeset_dirty?(%ProjectView{} = view) do
    case safe_changeset_call(fn -> Changeset.summary(changeset(view)) end) do
      [] -> false
      [_ | _] -> true
      {:ok, []} -> false
      {:ok, [_ | _]} -> true
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @spec owned_fork_store_dirty?(ProjectView.t()) :: boolean()
  defp owned_fork_store_dirty?(%ProjectView{} = view) do
    if owned_fork_store?(view) do
      case fork_store(view) do
        nil -> false
        fork_store -> fork_store_dirty?(fork_store)
      end
    else
      false
    end
  end

  @spec fork_store_dirty?(pid()) :: boolean()
  defp fork_store_dirty?(fork_store) when is_pid(fork_store) do
    try do
      map_size(BufferForkStore.all(fork_store)) > 0
    catch
      :exit, _ -> false
    end
  end

  @spec safe_changeset_call((-> term())) :: term() | {:error, term()}
  defp safe_changeset_call(fun) do
    try do
      fun.()
    catch
      :exit, reason -> {:error, {:changeset_unavailable, reason}}
    end
  end

  @spec fork_store_available(pid()) :: :ok | {:error, {:fork_unavailable, term()}}
  defp fork_store_available(fork_store) do
    try do
      _ = BufferForkStore.all(fork_store)
      :ok
    catch
      :exit, reason -> {:error, {:fork_unavailable, reason}}
    end
  end

  @spec maybe_stop_changeset(ProjectView.t()) :: :ok
  defp maybe_stop_changeset(%ProjectView{} = view) do
    case changeset(view) do
      changeset when is_pid(changeset) -> GenServer.stop(changeset, :normal)
    end
  catch
    :exit, _ -> :ok
  end

  @spec owned_fork_store?(ProjectView.t()) :: boolean()
  defp owned_fork_store?(%ProjectView{ref: %{owned_fork_store?: owned}}), do: owned

  @spec changeset(ProjectView.t()) :: pid()
  defp changeset(%ProjectView{ref: %{changeset: changeset}}), do: changeset

  @spec fork_store(ProjectView.t()) :: pid() | nil
  defp fork_store(%ProjectView{ref: %{fork_store: fork_store}}), do: fork_store

  @spec reject_tombstones([String.t()]) :: [String.t()]
  defp reject_tombstones(entries) do
    entries
    |> Enum.reject(&String.ends_with?(&1, ".__changeset_deleted__"))
    |> Enum.sort()
  end

  @spec directory_entry(String.t(), String.t()) :: ProjectView.Backend.directory_entry()
  defp directory_entry(dir, name) do
    type = if File.dir?(Path.join(dir, name)), do: :directory, else: :file
    %{name: name, type: type}
  end

  @spec fork_diff(ProjectView.t()) :: {:ok, [map()]} | {:error, term()}
  defp fork_diff(%ProjectView{} = view) do
    case fork_store(view) do
      nil ->
        {:ok, []}

      store ->
        entries =
          store
          |> BufferForkStore.all()
          |> Map.keys()
          |> Enum.map(&%{path: Path.relative_to(&1, view.project_root), kind: :modified})

        {:ok, entries}
    end
  catch
    :exit, reason -> {:error, {:fork_diff_failed, reason}}
  end

  @spec promote_forks(ProjectView.t()) :: :ok | {:conflict, map()} | {:error, term()}
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
    :exit, reason -> {:error, {:fork_promote_failed, reason}}
  end

  @spec fork_merge_result([{String.t(), :ok | {:conflict, term()} | {:error, term()}}]) ::
          :ok | {:conflict, map()}
  defp fork_merge_result(results) do
    failures = Enum.reject(results, &match?({_path, :ok}, &1))
    if failures == [], do: :ok, else: {:conflict, %{conflicts: failures, results: results}}
  end

  @spec discard_fork(ProjectView.t(), String.t()) :: :ok | {:error, term()}
  defp discard_fork(%ProjectView{} = view, relative_path) do
    case fork_store(view) do
      nil ->
        :ok

      store ->
        BufferForkStore.discard(store, Path.join(view.project_root, relative_path))
    end
  catch
    :exit, reason -> {:error, {:fork_discard_failed, reason}}
  end

  @spec discard_forks(ProjectView.t()) :: :ok | {:error, term()}
  defp discard_forks(%ProjectView{} = view) do
    case fork_store(view) do
      nil -> :ok
      store -> BufferForkStore.discard_all(store)
    end
  catch
    :exit, reason -> {:error, {:fork_discard_failed, reason}}
  end
end
