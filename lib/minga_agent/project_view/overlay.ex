# credo:disable-for-this-file Credo.Check.Readability.PreferImplicitTry
# credo:disable-for-this-file Credo.Check.Refactor.Nesting

defmodule MingaAgent.ProjectView.Overlay do
  @moduledoc """
  Overlay-backed project view backend.

  This backend delegates isolation to existing `MingaAgent.Changeset` and uses `MingaAgent.BufferForkStore` only for lifecycle operations when a fork store is provided.
  """

  @behaviour MingaAgent.ProjectView.Backend

  alias Minga.Buffer.Fork
  alias MingaAgent.BufferForkStore
  alias MingaAgent.Changeset
  alias MingaAgent.ProjectView
  alias MingaAgent.ProjectView.Source

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
    with {:ok, source} <- resolve_source(view, relative_path) do
      read_source(source)
    end
  end

  @impl true
  @spec resolve_source(ProjectView.t(), String.t()) :: {:ok, Source.t()} | {:error, term()}
  def resolve_source(%ProjectView{} = view, relative_path) do
    with :ok <- ensure_changeset_available(view),
         {:ok, buffer} <- buffer_candidate(view, relative_path),
         :ok <- capture_fork_baseline(view, relative_path, buffer),
         {:ok, owner} <-
           BufferForkStore.claim_owner(
             fork_store(view),
             buffer_path(view, relative_path),
             buffer,
             changeset(view)
           ) do
      {:ok, claimed_source(view, relative_path, owner)}
    else
      :not_found -> {:error, :source_unavailable}
      {:error, _} = error -> error
    end
  catch
    :exit, reason -> {:error, {:fork_unavailable, reason}}
  end

  @impl true
  @spec conditional_mutate(
          ProjectView.t(),
          String.t(),
          Minga.Buffer.FileMutation.expectation(),
          Minga.Buffer.FileMutation.operation()
        ) :: {:ok, Minga.Buffer.FileMutation.Receipt.t()} | {:error, term()}
  def conditional_mutate(%ProjectView{} = view, relative_path, expected, operation) do
    with :ok <- ensure_changeset_available(view),
         :ok <- fork_store_available(fork_store(view)),
         {:ok, source} <- resolve_source(view, relative_path) do
      mutate_source(source, expected, operation)
    end
  end

  @doc "Reads the content from the exact overlay owner returned with it."
  @spec review_source(ProjectView.t(), String.t()) ::
          {:ok, Source.t(), binary()} | {:error, term()}
  def review_source(%ProjectView{backend: __MODULE__} = view, relative_path) do
    with {:ok, source} <- ProjectView.resolve_source(view, relative_path),
         {:ok, content} <- read_source(source) do
      {:ok, source, content}
    end
  end

  @doc "Mutates only if the currently selected overlay owner matches the reviewed source."
  @spec conditional_review_mutate(
          ProjectView.t(),
          String.t(),
          Source.t(),
          Minga.Buffer.FileMutation.expectation(),
          Minga.Buffer.FileMutation.operation()
        ) :: {:ok, Minga.Buffer.FileMutation.Receipt.t()} | {:error, term()}
  def conditional_review_mutate(
        %ProjectView{backend: __MODULE__} = view,
        relative_path,
        reviewed,
        expected,
        operation
      ) do
    case ProjectView.resolve_source(view, relative_path) do
      {:ok, ^reviewed} -> mutate_source(reviewed, expected, operation)
      {:ok, %Source{}} -> {:error, :review_source_changed}
      {:error, _reason} = error -> error
    end
  end

  @spec mutate_source(
          Source.t(),
          Minga.Buffer.FileMutation.expectation(),
          Minga.Buffer.FileMutation.operation()
        ) :: {:ok, Minga.Buffer.FileMutation.Receipt.t()} | {:error, term()}
  defp mutate_source(%Source{source_id: id, owner: {:changeset, cs, path}}, expected, operation) do
    Changeset.conditional_mutate(cs, path, expected, operation, {:project_view, id})
  end

  defp mutate_source(%Source{source_id: id, owner: {:fork, fork}}, expected, operation) do
    Minga.Buffer.Fork.conditional_mutate(fork, expected, operation, {:project_view, id})
  end

  @impl true
  @spec write_file(ProjectView.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write_file(%ProjectView{} = view, relative_path, content) do
    with {:ok, source} <- resolve_source(view, relative_path) do
      case source.owner do
        {:fork, fork} -> Minga.Buffer.Fork.replace_content(fork, content)
        {:changeset, cs, path} -> Changeset.write_file(cs, path, content)
      end
    end
  end

  @impl true
  @spec edit_file(ProjectView.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def edit_file(%ProjectView{} = view, relative_path, old_text, new_text) do
    with {:ok, source} <- resolve_source(view, relative_path) do
      case source.owner do
        {:fork, fork} ->
          case Minga.Buffer.Fork.find_and_replace(fork, old_text, new_text) do
            {:ok, _message} -> :ok
            {:error, _} = error -> error
          end

        {:changeset, cs, path} ->
          Changeset.edit_file(cs, path, old_text, new_text)
      end
    end
  end

  @spec read_source(Source.t()) :: {:ok, binary()} | {:error, term()}
  defp read_source(%Source{owner: {:fork, fork}}), do: Minga.Buffer.Fork.read_file(fork)

  defp read_source(%Source{owner: {:changeset, cs, path}}),
    do: safe_changeset_call(fn -> Changeset.read_file(cs, path) end)

  @spec buffer_candidate(ProjectView.t(), String.t()) :: {:ok, pid() | nil} | {:error, term()}
  defp buffer_candidate(view, relative_path) do
    case open_buffer_pid(view, relative_path) do
      {:ok, buffer} -> {:ok, buffer}
      :not_found -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  @spec capture_fork_baseline(ProjectView.t(), String.t(), pid() | nil) ::
          :ok | {:error, term()}
  defp capture_fork_baseline(_view, _relative_path, nil), do: :ok

  defp capture_fork_baseline(view, relative_path, _buffer) do
    safe_changeset_call(fn -> Changeset.capture_original(changeset(view), relative_path) end)
  end

  @spec claimed_source(ProjectView.t(), String.t(), {:fork, pid()} | {:changeset, pid()}) ::
          Source.t()
  defp claimed_source(view, relative_path, {:fork, fork}) do
    Source.fork(buffer_path(view, relative_path), fork)
  end

  defp claimed_source(view, relative_path, {:changeset, cs}) do
    Source.changeset(buffer_path(view, relative_path), cs, relative_path)
  end

  @spec open_buffer_pid(ProjectView.t(), String.t()) ::
          {:ok, pid()} | :not_found | {:error, term()}
  defp open_buffer_pid(%ProjectView{} = view, relative_path) do
    Minga.Buffer.pid_for_path(buffer_path(view, relative_path))
  rescue
    _ -> {:error, {:buffer_lookup_failed, relative_path}}
  end

  @spec buffer_path(ProjectView.t(), String.t()) :: String.t()
  defp buffer_path(%ProjectView{} = view, relative_path) do
    Path.join(view.project_root, relative_path)
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
    with {:ok, source} <- resolve_source(view, relative_path) do
      case source.owner do
        {:changeset, cs, path} ->
          Changeset.delete_file(cs, path)

        {:fork, fork} ->
          with {:ok, content} <- Minga.Buffer.Fork.read_file(fork) do
            expected =
              Minga.Buffer.FileMutation.revision(content, nil, {:project_view, source.source_id})

            mutate_source(source, expected, :delete)
          end
      end
    end
  end

  @impl true
  @spec list_directory(ProjectView.t(), String.t()) ::
          {:ok, [ProjectView.Backend.directory_entry()]} | {:error, term()}
  def list_directory(%ProjectView{} = view, relative_path) do
    with {:ok, entries} <-
           safe_changeset_call(fn -> Changeset.list_directory(changeset(view), relative_path) end),
         {:ok, drafts} <- fork_diff(view) do
      deleted = MapSet.new(for %{path: path, kind: :deleted} <- drafts, do: path)
      {:ok, Enum.reject(entries, &MapSet.member?(deleted, Path.join(relative_path, &1.name)))}
    end
  end

  @impl true
  @spec working_dir(ProjectView.t()) :: String.t() | {:error, term()}
  def working_dir(%ProjectView{} = view),
    do: safe_changeset_call(fn -> Changeset.overlay_path(changeset(view)) end)

  @impl true
  @spec prepare_working_dir(ProjectView.t()) :: {:ok, String.t()} | {:error, term()}
  def prepare_working_dir(%ProjectView{} = view) do
    with {:ok, _stats} <-
           safe_changeset_call(fn ->
             GenServer.call(changeset(view), :materialize_for_command, :infinity)
           end),
         :ok <- materialize_open_fork_drafts(view) do
      {:ok, Changeset.overlay_path(changeset(view))}
    end
  end

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
         {:ok, fork_results} <- promote_forks(view) do
      merge_result = safe_changeset_call(fn -> Changeset.merge(changeset(view)) end)
      combine_publication_results(fork_results, merge_result)
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

  @doc "Reads conflict regions for the fork currently owned by this project view."
  @spec fork_conflict_snapshot(ProjectView.t(), String.t()) ::
          {:ok, Fork.review_revision(), [Minga.Core.Diff.merge_region()]} | {:error, term()}
  def fork_conflict_snapshot(view, relative_path) do
    with {:ok, _store, _path, fork} <- review_fork(view, relative_path) do
      Fork.conflict_snapshot(fork)
    end
  catch
    :exit, _ -> {:error, :fork_unavailable}
  end

  @doc "Stages a reviewed fork resolution and transfers the sealed fork to the changeset."
  @spec resolve_fork_conflicts(ProjectView.t(), String.t(), Fork.review_revision(), [
          :accepted | :rejected
        ]) :: :ok | {:conflict, term()} | {:error, term()}
  def resolve_fork_conflicts(view, relative_path, revision, decisions) do
    cs = changeset(view)

    with {:ok, store, path, fork} <- review_fork(view, relative_path) do
      BufferForkStore.publish_reviewed_fork(store, path, fork, cs, fn ->
        Fork.publish_resolution(fork, revision, decisions, fn ancestor, selected ->
          Changeset.stage_fork_resolution(cs, relative_path, ancestor, selected)
        end)
      end)
    end
  catch
    :exit, _ -> {:error, :fork_unavailable}
  end

  @spec review_fork(ProjectView.t(), String.t()) ::
          {:ok, pid(), String.t(), pid()} | {:error, term()}
  defp review_fork(view, relative_path) do
    with {:ok, normalized} <- ProjectView.normalize_relative_path(relative_path),
         store when is_pid(store) <- fork_store(view),
         path = Path.join(view.project_root, normalized),
         fork when is_pid(fork) <- BufferForkStore.get(store, path) do
      {:ok, store, path, fork}
    else
      nil -> {:error, :fork_unavailable}
      {:error, _} = error -> error
    end
  end

  @spec combine_publication_results([tuple()], :ok | {:conflict, map()} | {:error, term()}) ::
          :ok | {:conflict, map()} | {:error, term()}
  defp combine_publication_results(fork_results, :ok) do
    case publication_failures(fork_results) do
      [] -> :ok
      failures -> {:conflict, %{results: fork_results, conflicts: failures}}
    end
  end

  defp combine_publication_results(fork_results, {:conflict, details}) do
    results =
      (fork_results ++ details.results)
      |> Map.new(fn result -> {elem(result, 1), result} end)
      |> Map.values()
      |> Enum.sort_by(&elem(&1, 1))

    {:conflict, %{details | results: results, conflicts: publication_failures(results)}}
  end

  defp combine_publication_results([], {:error, _} = error), do: error

  defp combine_publication_results(fork_results, {:error, reason}) do
    {:conflict, %{results: fork_results, conflicts: [{:error, :changeset, reason}]}}
  end

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
      Enum.any?(BufferForkStore.all(fork_store), fn {_path, fork} ->
        Minga.Buffer.Fork.dirty?(fork)
      end)
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

  @spec materialize_open_fork_drafts(ProjectView.t()) :: :ok | {:error, term()}
  defp materialize_open_fork_drafts(%ProjectView{} = view) do
    case fork_store(view) do
      nil ->
        :ok

      fork_store ->
        with :ok <- fork_store_available(fork_store) do
          fork_store
          |> BufferForkStore.all()
          |> Enum.reduce_while(:ok, fn {path, _fork}, :ok ->
            with {:ok, relative_path} <- fork_relative_path(view, path),
                 :ok <-
                   BufferForkStore.materialize_owned_fork(fork_store, path, fn fork ->
                     materialize_fork(view, relative_path, fork)
                   end) do
              {:cont, :ok}
            else
              {:error, _} = error -> {:halt, error}
            end
          end)
        end
    end
  end

  @spec materialize_fork(ProjectView.t(), String.t(), pid()) :: :ok | {:error, term()}
  defp materialize_fork(view, relative_path, fork) do
    case Minga.Buffer.Fork.read_file(fork) do
      {:ok, content} ->
        safe_changeset_call(fn ->
          Changeset.materialize_command_file(changeset(view), relative_path, content)
        end)

      {:error, :enoent} ->
        safe_changeset_call(fn ->
          Changeset.materialize_command_deletion(changeset(view), relative_path)
        end)
    end
  end

  @spec fork_relative_path(ProjectView.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp fork_relative_path(%ProjectView{} = view, path) do
    root = Path.expand(view.project_root)
    target = Path.expand(path)

    if String.starts_with?(target, root <> "/") do
      ProjectView.normalize_relative_path(Path.relative_to(target, root))
    else
      {:error, :path_traversal}
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

  @spec fork_diff(ProjectView.t()) :: {:ok, [map()]} | {:error, term()}
  defp fork_diff(%ProjectView{} = view) do
    case fork_store(view) do
      nil ->
        {:ok, []}

      store ->
        entries =
          store
          |> BufferForkStore.all()
          |> Enum.filter(fn {_path, fork} -> Minga.Buffer.Fork.dirty?(fork) end)
          |> Enum.map(fn {path, fork} ->
            kind = if Minga.Buffer.Fork.status(fork) == :deleted, do: :deleted, else: :modified
            %{path: Path.relative_to(path, view.project_root), kind: kind}
          end)

        {:ok, entries}
    end
  catch
    :exit, reason -> {:error, {:fork_diff_failed, reason}}
  end

  @spec promote_forks(ProjectView.t()) ::
          {:ok, [tuple()]} | {:conflict, map()} | {:error, term()}
  defp promote_forks(%ProjectView{} = view) do
    case fork_store(view) do
      nil ->
        {:ok, []}

      store ->
        case fork_store_available(store) do
          :ok ->
            results =
              store
              |> BufferForkStore.all()
              |> Enum.map(fn {path, fork} -> publish_fork(view, store, path, fork) end)

            case publication_failures(results) do
              [] -> {:ok, results}
              failures -> {:conflict, %{conflicts: failures, results: results}}
            end

          {:error, {:fork_unavailable, reason}} ->
            {:error, {:fork_promote_failed, reason}}
        end
    end
  end

  @spec publish_fork(ProjectView.t(), pid(), String.t(), pid()) :: tuple()
  defp publish_fork(view, store, path, fork) do
    with {:ok, relative_path} <- fork_relative_path(view, path),
         {:ok, kind} <- publish_fork_draft(view, relative_path, fork) do
      case BufferForkStore.transfer_to_changeset(store, path, fork, changeset(view)) do
        :ok -> {:ok, relative_path, kind}
        {:error, reason} -> {:error, relative_path, {:owner_transfer_failed, kind, reason}}
      end
    else
      {:conflict, reason} -> {:conflict, Path.relative_to(path, view.project_root), reason}
      {:error, reason} -> {:error, Path.relative_to(path, view.project_root), reason}
    end
  catch
    :exit, reason ->
      {:error, Path.relative_to(path, view.project_root), {:fork_promote_failed, reason}}
  end

  @spec publish_fork_draft(ProjectView.t(), String.t(), pid()) ::
          {:ok, :staged | :unchanged | :deleted} | {:conflict, term()} | {:error, term()}
  defp publish_fork_draft(view, relative_path, fork) do
    case Fork.status(fork) do
      :present ->
        case Fork.publish(fork, fn raw_content ->
               Changeset.stage_fork_content(changeset(view), relative_path, raw_content)
             end) do
          {:ok, _merged} ->
            kind = if Fork.dirty?(fork), do: :staged, else: :unchanged
            {:ok, kind}

          result ->
            result
        end

      :deleted ->
        case Fork.publish_deletion(fork, fn ->
               Changeset.publish_deletion(changeset(view), relative_path)
             end) do
          :ok -> {:ok, :deleted}
          result -> result
        end
    end
  end

  @spec publication_failures([tuple()]) :: [tuple()]
  defp publication_failures(results), do: Enum.reject(results, &match?({:ok, _, _}, &1))

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
