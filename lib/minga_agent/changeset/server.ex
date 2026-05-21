defmodule MingaAgent.Changeset.Server do
  @moduledoc """
  GenServer managing a single changeset's lifecycle.

  Holds modified file contents in memory and keeps the overlay directory
  in sync. Maintains an edit history per file for undo support.
  Integrates three-way merge via `Minga.Core.Diff.merge3/3`.
  """

  use GenServer, restart: :temporary

  alias Minga.Core.Overlay
  alias MingaAgent.Changeset.MergedEvent

  @typedoc "Internal server state."
  @type state :: %{
          project_root: String.t(),
          overlay: Overlay.t(),
          snapshots: %{String.t() => binary()},
          modifications: %{String.t() => binary()},
          originals: %{String.t() => binary()},
          deletions: MapSet.t(String.t()),
          history: %{String.t() => [binary() | :unmodified]},
          budget: pos_integer() | :unlimited,
          attempts: non_neg_integer()
        }

  @skip_dirs MapSet.new(~w(_build .git .elixir_ls node_modules .hex deps))

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  @spec init(keyword()) :: {:ok, state()} | {:stop, term()}
  def init(opts) do
    project_root = Keyword.fetch!(opts, :project_root)
    budget = Keyword.get(opts, :budget, :unlimited)

    case Overlay.create(project_root) do
      {:ok, overlay} ->
        baselines = baseline_overlay_files(project_root, overlay.overlay_dir)

        state = %{
          project_root: project_root,
          overlay: overlay,
          snapshots: snapshot_overlay_files(project_root, overlay.overlay_dir),
          modifications: %{},
          originals: baselines,
          deletions: MapSet.new(),
          history: %{},
          budget: budget,
          attempts: 0
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl GenServer
  def handle_call({:write_file, relative_path, content}, _from, state) do
    case normalize_path(state, relative_path) do
      {:ok, path} ->
        previous = previous_content(state, path)

        case Overlay.materialize_file(state.overlay, path, content) do
          :ok ->
            state = push_history(state, path, previous)
            state = put_in(state.modifications[path], content)
            state = %{state | deletions: MapSet.delete(state.deletions, path)}
            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:edit_file, relative_path, old_text, new_text}, _from, state) do
    case normalize_path(state, relative_path) do
      {:ok, path} ->
        case apply_edit(state, path, old_text, new_text) do
          {:ok, new_state} -> {:reply, :ok, new_state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete_file, relative_path}, _from, state) do
    case normalize_path(state, relative_path) do
      {:ok, path} ->
        previous = previous_content(state, path)

        case Overlay.delete_file(state.overlay, path) do
          :ok ->
            state = push_history(state, path, previous)
            state = %{state | deletions: MapSet.put(state.deletions, path)}
            state = %{state | modifications: Map.delete(state.modifications, path)}
            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:undo, relative_path}, _from, state) do
    case normalize_path(state, relative_path) do
      {:ok, path} -> undo_path(path, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:read_file, relative_path}, _from, state) do
    case normalize_path(state, relative_path) do
      {:ok, path} -> {:reply, current_content(state, path), state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:overlay_path, _from, state) do
    {:reply, state.overlay.overlay_dir, state}
  end

  def handle_call(:project_root, _from, state) do
    {:reply, state.project_root, state}
  end

  def handle_call(:command_env, _from, state) do
    {:reply, Overlay.command_env(state.overlay), state}
  end

  def handle_call(:modified_files, _from, state) do
    tracked = tracked_entries(state)

    modified =
      tracked |> Enum.reject(&(&1.kind == :deleted)) |> Enum.map(& &1.path) |> Enum.sort()

    deleted = tracked |> Enum.filter(&(&1.kind == :deleted)) |> Enum.map(& &1.path) |> Enum.sort()
    {:reply, %{modified: modified, deleted: deleted}, state}
  end

  def handle_call(:summary, _from, state) do
    tracked = tracked_entries(state)
    filesystem = filesystem_summary(state) |> Enum.reject(&tracked_path?(state, &1.path))

    entries = tracked ++ filesystem
    {:reply, Enum.sort_by(Enum.uniq_by(entries, & &1.path), & &1.path), state}
  end

  def handle_call(:record_attempt, _from, state) do
    state = %{state | attempts: state.attempts + 1}

    case state.budget do
      :unlimited ->
        {:reply, {:ok, state.attempts}, state}

      budget when state.attempts > budget ->
        {:reply, {:budget_exhausted, state.attempts, budget}, state}

      _budget ->
        {:reply, {:ok, state.attempts}, state}
    end
  end

  def handle_call(:attempt_info, _from, state) do
    {:reply, %{attempts: state.attempts, budget: state.budget}, state}
  end

  def handle_call(:reset, _from, state) do
    case Overlay.create(state.project_root) do
      {:ok, overlay} ->
        Overlay.cleanup(state.overlay)
        baselines = baseline_overlay_files(state.project_root, overlay.overlay_dir)

        state = %{
          state
          | overlay: overlay,
            snapshots: snapshot_overlay_files(state.project_root, overlay.overlay_dir),
            modifications: %{},
            originals: baselines,
            deletions: MapSet.new(),
            history: %{}
        }

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:merge, _from, state) do
    case do_merge(state) do
      :ok ->
        Overlay.cleanup(state.overlay)
        broadcast_merged(state)
        {:stop, :normal, :ok, state}

      {:conflict, details} ->
        state = prune_successful_merge_results(state, details.results)
        {:reply, {:conflict, details}, state}

      {:error, errors} ->
        {:reply, {:error, errors}, state}
    end
  rescue
    e ->
      {:reply, {:error, Exception.message(e)}, state}
  end

  def handle_call(:discard, _from, state) do
    Overlay.cleanup(state.overlay)
    {:stop, :normal, :ok, state}
  end

  @impl GenServer
  def terminate(_reason, %{overlay: %Overlay{} = overlay}) do
    Overlay.cleanup(overlay)
  end

  def terminate(_reason, _state), do: :ok

  # ── Merge logic ─────────────────────────────────────────────────────────────

  @spec do_merge(state()) :: :ok | {:conflict, map()} | {:error, [tuple()]}
  defp do_merge(state) do
    modification_results =
      Enum.map(state.modifications, fn {path, changeset_content} ->
        merge_one_file(state, path, changeset_content)
      end)

    deletion_results =
      Enum.map(state.deletions, fn path ->
        merge_one_deletion(state, path)
      end)

    filesystem_results =
      state
      |> filesystem_summary()
      |> Enum.reject(&tracked_path?(state, &1.path))
      |> Enum.map(&merge_filesystem_entry(state, &1.path))

    all_results = modification_results ++ deletion_results ++ filesystem_results
    errors = Enum.filter(all_results, &match?({:error, _, _}, &1))
    conflicts = Enum.filter(all_results, &match?({:conflict, _, _}, &1))

    if errors == [] do
      if conflicts == [] do
        :ok
      else
        {:conflict, %{conflicts: conflicts, results: all_results}}
      end
    else
      {:error, errors}
    end
  end

  @spec prune_successful_merge_results(state(), [tuple()]) :: state()
  defp prune_successful_merge_results(state, results) do
    Enum.reduce(results, state, &prune_successful_merge_result/2)
  end

  @spec prune_successful_merge_result(tuple(), state()) :: state()
  defp prune_successful_merge_result({:ok, path, _kind}, state) do
    state
    |> sync_merge_snapshot(path)
    |> sync_merge_baseline(path)
    |> drop_merge_tracking(path)
  end

  defp prune_successful_merge_result(_result, state), do: state

  @spec drop_merge_tracking(state(), String.t()) :: state()
  defp drop_merge_tracking(state, path) do
    %{
      state
      | modifications: Map.delete(state.modifications, path),
        deletions: MapSet.delete(state.deletions, path),
        history: Map.delete(state.history, path)
    }
  end

  @spec sync_merge_snapshot(state(), String.t()) :: state()
  defp sync_merge_snapshot(state, path) do
    overlay_path = Path.join(state.overlay.overlay_dir, path)

    case File.read(overlay_path) do
      {:ok, content} -> put_in(state.snapshots[path], file_signature_from_content(content))
      {:error, :enoent} -> %{state | snapshots: Map.delete(state.snapshots, path)}
      {:error, _reason} -> state
    end
  end

  @spec sync_merge_baseline(state(), String.t()) :: state()
  defp sync_merge_baseline(state, path) do
    overlay_path = Path.join(state.overlay.overlay_dir, path)

    case File.read(overlay_path) do
      {:ok, content} -> put_in(state.originals[path], content)
      {:error, :enoent} -> %{state | originals: Map.delete(state.originals, path)}
      {:error, _reason} -> state
    end
  end

  @spec merge_one_file(state(), String.t(), binary()) :: tuple()
  defp merge_one_file(state, path, _changeset_content) do
    merge_overlay_state(state, path, current_overlay_state(state, path))
  end

  @spec merge_overlay_state(state(), String.t(), {:ok, binary()} | :deleted | {:error, term()}) ::
          tuple()
  defp merge_overlay_state(state, path, {:ok, current_changeset_content}) do
    real_path = Path.join(state.project_root, path)
    merge_current_content(state, path, real_path, current_changeset_content)
  end

  defp merge_overlay_state(state, path, :deleted), do: merge_one_deletion(state, path)
  defp merge_overlay_state(_state, path, {:error, reason}), do: {:error, path, reason}

  @spec merge_current_content(state(), String.t(), String.t(), binary()) :: tuple()
  defp merge_current_content(state, path, real_path, current_changeset_content) do
    case current_real_content(real_path) do
      {:ok, current_real} ->
        merge_with_ancestor(state, path, real_path, current_real, current_changeset_content)

      {:error, reason} ->
        {:error, path, reason}
    end
  end

  @spec merge_with_ancestor(state(), String.t(), String.t(), binary() | nil, binary()) :: tuple()
  defp merge_with_ancestor(state, path, real_path, current_real, current_changeset_content) do
    case merge_ancestor_content(state, path, current_real) do
      {:ok, original} ->
        merge_strategy(real_path, path, original, current_real, current_changeset_content)

      {:conflict, conflict_path, reason} ->
        {:conflict, conflict_path, reason}
    end
  end

  # New file: didn't exist when changeset was created
  @spec merge_strategy(String.t(), String.t(), binary() | nil, binary() | nil, binary()) ::
          tuple()
  defp merge_strategy(real_path, path, nil = _original, nil = _current_real, changeset_content) do
    File.mkdir_p!(Path.dirname(real_path))
    File.write!(real_path, changeset_content)
    {:ok, path, :created}
  end

  # New file but someone else also created it
  defp merge_strategy(_real_path, path, nil = _original, _current_real, _changeset_content) do
    {:conflict, path, :both_created}
  end

  # Real file disappeared, restore the changeset content.
  defp merge_strategy(real_path, path, _original, nil, changeset_content) do
    File.mkdir_p!(Path.dirname(real_path))
    File.write!(real_path, changeset_content)
    {:ok, path, :restored}
  end

  # Real file unchanged since changeset was created: apply directly
  defp merge_strategy(real_path, path, original, current_real, changeset_content)
       when current_real == original do
    File.write!(real_path, changeset_content)
    {:ok, path, :applied}
  end

  # Real file was also modified: three-way merge
  defp merge_strategy(real_path, path, original, current_real, changeset_content) do
    ancestor_lines = String.split(original, "\n", trim: false)
    ours_lines = String.split(changeset_content, "\n", trim: false)
    theirs_lines = String.split(current_real, "\n", trim: false)

    case Minga.Core.Diff.merge3(ancestor_lines, ours_lines, theirs_lines) do
      {:ok, merged_lines} ->
        File.write!(real_path, Enum.join(merged_lines, "\n"))
        {:ok, path, :merged_three_way}

      {:conflict, _hunks} ->
        {:conflict, path, :concurrent_edit}
    end
  end

  @spec merge_one_deletion(state(), String.t()) :: tuple()
  defp merge_one_deletion(state, path) do
    real_path = Path.join(state.project_root, path)
    merge_deletion_overlay_state(state, path, real_path, current_overlay_state(state, path))
  end

  @spec merge_deletion_overlay_state(
          state(),
          String.t(),
          String.t(),
          {:ok, binary()} | :deleted | {:error, term()}
        ) :: tuple()
  defp merge_deletion_overlay_state(state, path, real_path, {:ok, current_changeset_content}) do
    merge_current_content(state, path, real_path, current_changeset_content)
  end

  defp merge_deletion_overlay_state(state, path, real_path, :deleted) do
    case current_real_content(real_path) do
      {:ok, current_real} -> merge_deleted_file(state, path, real_path, current_real)
      {:error, reason} -> {:error, path, reason}
    end
  end

  defp merge_deletion_overlay_state(_state, path, _real_path, {:error, reason}),
    do: {:error, path, reason}

  @spec merge_deleted_file(state(), String.t(), String.t(), binary() | nil) :: tuple()
  defp merge_deleted_file(state, path, _real_path, nil) do
    case merge_ancestor_content(state, path, nil) do
      {:ok, _original} -> {:ok, path, :already_deleted}
      {:conflict, conflict_path, reason} -> {:conflict, conflict_path, reason}
    end
  end

  defp merge_deleted_file(state, path, real_path, content) do
    case merge_ancestor_content(state, path, content) do
      {:ok, ^content} ->
        File.rm!(real_path)
        {:ok, path, :deleted}

      {:ok, _original} ->
        {:conflict, path, :modified_before_delete}

      {:conflict, conflict_path, reason} ->
        {:conflict, conflict_path, reason}
    end
  end

  @spec merge_ancestor_content(state(), String.t(), binary() | nil) ::
          {:ok, binary() | nil} | {:conflict, String.t(), term()}
  defp merge_ancestor_content(state, path, current_real) do
    case Map.fetch(state.originals, path) do
      {:ok, original} -> {:ok, original}
      :error -> merge_snapshot_ancestor(state, path, current_real)
    end
  end

  @spec merge_snapshot_ancestor(state(), String.t(), binary() | nil) ::
          {:ok, binary() | nil} | {:conflict, String.t(), term()}
  defp merge_snapshot_ancestor(%{snapshots: snapshots}, path, current_real) do
    case Map.fetch(snapshots, path) do
      :error -> {:ok, nil}
      {:ok, snapshot_signature} -> merge_snapshot_ancestor(path, current_real, snapshot_signature)
    end
  end

  @spec merge_snapshot_ancestor(String.t(), binary() | nil, binary()) ::
          {:ok, binary() | nil} | {:conflict, String.t(), term()}
  defp merge_snapshot_ancestor(path, current_real, snapshot_signature)
       when is_binary(current_real) do
    if file_signature_from_content(current_real) == snapshot_signature do
      {:ok, current_real}
    else
      {:conflict, path, :missing_merge_base}
    end
  end

  defp merge_snapshot_ancestor(path, _current_real, _snapshot_signature),
    do: {:conflict, path, :missing_merge_base}

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec undo_path(String.t(), state()) :: {:reply, :ok | {:error, term()}, state()}
  defp undo_path(path, state) do
    case Map.get(state.history, path) do
      [prev | rest] ->
        state = put_in(state.history[path], rest)

        if prev == :unmodified do
          state = %{state | modifications: Map.delete(state.modifications, path)}
          state = %{state | deletions: MapSet.delete(state.deletions, path)}
          restore_original(state, path)
          {:reply, :ok, state}
        else
          Overlay.materialize_file(state.overlay, path, prev)
          state = put_in(state.modifications[path], prev)
          state = %{state | deletions: MapSet.delete(state.deletions, path)}
          {:reply, :ok, state}
        end

      _ ->
        {:reply, {:error, :nothing_to_undo}, state}
    end
  end

  @spec apply_edit(state(), String.t(), String.t(), String.t()) ::
          {:ok, state()} | {:error, term()}
  defp apply_edit(state, path, old_text, new_text) do
    with {:ok, content} <- current_content(state, path),
         true <- String.contains?(content, old_text) do
      new_content = String.replace(content, old_text, new_text, global: false)

      case Overlay.materialize_file(state.overlay, path, new_content) do
        :ok ->
          state = push_history(state, path, content)
          {:ok, put_in(state.modifications[path], new_content)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :text_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec current_content(state(), String.t()) :: {:ok, binary()} | {:error, term()}
  defp current_content(state, path) do
    case current_overlay_state(state, path) do
      {:ok, content} -> {:ok, content}
      :deleted -> {:error, :deleted}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec current_overlay_state(state(), String.t()) ::
          {:ok, binary()} | :deleted | {:error, term()}
  defp current_overlay_state(state, path) do
    overlay_path = Path.join(state.overlay.overlay_dir, path)
    root_path = Path.join(state.project_root, path)

    case File.read(overlay_path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        if Map.has_key?(state.snapshots, path) or File.exists?(tombstone_path(overlay_path)) do
          :deleted
        else
          File.read(root_path)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec current_real_content(String.t()) :: {:ok, binary() | nil} | {:error, term()}
  defp current_real_content(real_path) do
    case File.read(real_path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec source_content(state(), String.t()) :: {:ok, binary()} | {:error, term()}
  defp source_content(state, path) do
    case current_overlay_state(state, path) do
      {:ok, content} -> {:ok, content}
      :deleted -> {:error, :deleted}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec previous_content(state(), String.t()) :: binary() | :unmodified
  defp previous_content(state, path) do
    case source_content(state, path) do
      {:ok, content} -> content
      {:error, _} -> :unmodified
    end
  end

  @spec tombstone_path(String.t()) :: String.t()
  defp tombstone_path(path), do: path <> ".__changeset_deleted__"

  @spec push_history(state(), String.t(), binary() | :unmodified) :: state()
  defp push_history(state, path, current) do
    history = Map.get(state.history, path, [])
    put_in(state.history[path], [current | history])
  end

  @spec restore_original(state(), String.t()) :: :ok
  defp restore_original(state, path) do
    overlay_path = Path.join(state.overlay.overlay_dir, path)
    project_path = Path.join(state.project_root, path)

    File.rm(overlay_path)
    File.rm(tombstone_path(overlay_path))

    if File.regular?(project_path) do
      File.mkdir_p!(Path.dirname(overlay_path))
      relink_file(state.overlay, project_path, overlay_path)
    end

    :ok
  end

  @spec relink_file(Overlay.t(), String.t(), String.t()) :: :ok
  defp relink_file(%Overlay{}, source, target) do
    File.cp!(source, target)
  end

  @spec filesystem_summary(state()) :: [map()]
  defp filesystem_summary(state) do
    filesystem_paths(state)
    |> Enum.flat_map(&filesystem_summary_entry(state, &1))
    |> Enum.uniq_by(& &1.path)
    |> Enum.sort_by(& &1.path)
  end

  @spec filesystem_paths(state()) :: [String.t()]
  defp filesystem_paths(%{overlay: %Overlay{overlay_dir: overlay_dir}, snapshots: snapshots}) do
    overlay_files = collect_regular_files(overlay_dir, "")
    (Map.keys(snapshots) ++ overlay_files) |> Enum.uniq()
  end

  @spec filesystem_summary_entry(state(), String.t()) :: [map()]
  defp filesystem_summary_entry(state, path) do
    overlay_path = Path.join(state.overlay.overlay_dir, path)
    snapshot = Map.get(state.snapshots, path)

    case {snapshot, file_signature(overlay_path)} do
      {nil, {:ok, _overlay_signature}} ->
        [%{path: path, kind: :new, size: file_size(overlay_path)}]

      {nil, {:error, :enoent}} ->
        []

      {snapshot_signature, {:ok, overlay_signature}} ->
        if overlay_signature == snapshot_signature do
          []
        else
          [%{path: path, kind: :modified, size: file_size(overlay_path)}]
        end

      {_snapshot_signature, {:error, :enoent}} ->
        [%{path: path, kind: :deleted, size: 0}]

      {_snapshot_signature, {:error, reason}} ->
        [%{path: path, kind: :error, size: 0, reason: reason}]
    end
  end

  @spec merge_filesystem_entry(state(), String.t()) :: tuple()
  defp merge_filesystem_entry(state, path) do
    overlay_path = Path.join(state.overlay.overlay_dir, path)
    root_path = Path.join(state.project_root, path)
    overlay_read = File.read(overlay_path)
    root_read = File.read(root_path)

    case Map.fetch(state.snapshots, path) do
      :error ->
        merge_new_filesystem_entry(path, root_path, overlay_read, root_read)

      {:ok, snapshot_signature} ->
        merge_snapshot_filesystem_entry(
          path,
          root_path,
          snapshot_signature,
          overlay_read,
          root_read
        )
    end
  end

  @spec merge_new_filesystem_entry(
          String.t(),
          String.t(),
          {:ok, binary()} | {:error, term()},
          {:ok, binary()} | {:error, term()}
        ) :: tuple()
  defp merge_new_filesystem_entry(path, root_path, {:ok, overlay_content}, {:error, :enoent}) do
    File.mkdir_p!(Path.dirname(root_path))
    File.write!(root_path, overlay_content)
    {:ok, path, :created}
  end

  defp merge_new_filesystem_entry(path, _root_path, {:ok, overlay_content}, {:ok, root_content}) do
    if overlay_content == root_content do
      {:ok, path, :already_applied}
    else
      {:conflict, path, :both_created}
    end
  end

  defp merge_new_filesystem_entry(path, _root_path, {:ok, _overlay_content}, {:error, reason}),
    do: {:error, path, reason}

  defp merge_new_filesystem_entry(path, _root_path, {:error, :enoent}, {:error, :enoent}),
    do: {:ok, path, :already_deleted}

  defp merge_new_filesystem_entry(path, _root_path, {:error, :enoent}, {:ok, _root_content}),
    do: {:ok, path, :already_applied}

  defp merge_new_filesystem_entry(path, _root_path, {:error, reason}, _root_read),
    do: {:error, path, reason}

  @spec merge_snapshot_filesystem_entry(
          String.t(),
          String.t(),
          binary(),
          {:ok, binary()} | {:error, term()},
          {:ok, binary()} | {:error, term()}
        ) :: tuple()
  defp merge_snapshot_filesystem_entry(
         path,
         root_path,
         snapshot_signature,
         {:error, :enoent},
         {:ok, root_content}
       ) do
    merge_snapshot_delete(path, root_path, snapshot_signature, root_content)
  end

  defp merge_snapshot_filesystem_entry(
         path,
         _root_path,
         _snapshot_signature,
         {:error, :enoent},
         {:error, :enoent}
       ) do
    {:ok, path, :already_deleted}
  end

  defp merge_snapshot_filesystem_entry(
         path,
         _root_path,
         _snapshot_signature,
         {:ok, _overlay_content},
         {:error, :enoent}
       ) do
    {:conflict, path, :missing_project_file}
  end

  defp merge_snapshot_filesystem_entry(
         path,
         root_path,
         snapshot_signature,
         {:ok, overlay_content},
         {:ok, root_content}
       ) do
    merge_existing_snapshot_file(
      snapshot_signature,
      overlay_content,
      root_content,
      path,
      root_path
    )
  end

  defp merge_snapshot_filesystem_entry(
         path,
         _root_path,
         _snapshot_signature,
         {:error, reason},
         _root_read
       ),
       do: {:error, path, reason}

  defp merge_snapshot_filesystem_entry(
         path,
         _root_path,
         _snapshot_signature,
         _overlay_read,
         {:error, reason}
       ),
       do: {:error, path, reason}

  @spec merge_snapshot_delete(String.t(), String.t(), binary(), binary()) :: tuple()
  defp merge_snapshot_delete(path, root_path, snapshot_signature, root_content) do
    if file_signature_from_content(root_content) == snapshot_signature do
      File.rm!(root_path)
      {:ok, path, :deleted}
    else
      {:conflict, path, :modified_before_delete}
    end
  end

  @spec merge_existing_snapshot_file(binary(), binary(), binary(), String.t(), String.t()) ::
          tuple()
  defp merge_existing_snapshot_file(
         snapshot_signature,
         overlay_content,
         root_content,
         path,
         root_path
       ) do
    overlay_signature = file_signature_from_content(overlay_content)
    root_signature = file_signature_from_content(root_content)

    merge_existing_snapshot_file(
      snapshot_signature,
      overlay_signature,
      root_signature,
      overlay_content,
      path,
      root_path
    )
  end

  @spec merge_existing_snapshot_file(
          binary(),
          binary(),
          binary(),
          binary(),
          String.t(),
          String.t()
        ) :: tuple()
  defp merge_existing_snapshot_file(
         snapshot_signature,
         snapshot_signature,
         _root_signature,
         _overlay_content,
         path,
         _root_path
       ),
       do: {:ok, path, :already_applied}

  defp merge_existing_snapshot_file(
         _snapshot_signature,
         same_signature,
         same_signature,
         _overlay_content,
         path,
         _root_path
       ),
       do: {:ok, path, :already_applied}

  defp merge_existing_snapshot_file(
         snapshot_signature,
         _overlay_signature,
         snapshot_signature,
         overlay_content,
         path,
         root_path
       ) do
    File.write!(root_path, overlay_content)
    {:ok, path, :applied}
  end

  defp merge_existing_snapshot_file(
         _snapshot_signature,
         _overlay_signature,
         _root_signature,
         _overlay_content,
         path,
         _root_path
       ),
       do: {:conflict, path, :concurrent_edit}

  @spec collect_regular_files(String.t(), String.t()) :: [String.t()]
  defp collect_regular_files(dir, rel_prefix) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.flat_map(entries, &collect_regular_file_entry(dir, rel_prefix, &1))
      {:error, _} -> []
    end
  end

  @spec collect_regular_file_entry(String.t(), String.t(), String.t()) :: [String.t()]
  defp collect_regular_file_entry(dir, rel_prefix, entry) do
    if skip_overlay_entry?(entry) do
      []
    else
      path = Path.join(dir, entry)
      rel_path = relative_entry_path(rel_prefix, entry)
      collect_regular_file_path(path, rel_path)
    end
  end

  @spec collect_regular_file_path(String.t(), String.t()) :: [String.t()]
  defp collect_regular_file_path(path, rel_path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> [rel_path]
      {:ok, %{type: :directory}} -> collect_regular_files(path, rel_path)
      _ -> []
    end
  end

  @spec skip_overlay_entry?(String.t()) :: boolean()
  defp skip_overlay_entry?(entry) do
    MapSet.member?(@skip_dirs, entry) or String.ends_with?(entry, ".__changeset_deleted__")
  end

  @spec relative_entry_path(String.t(), String.t()) :: String.t()
  defp relative_entry_path("", entry), do: entry
  defp relative_entry_path(rel_prefix, entry), do: Path.join(rel_prefix, entry)

  @spec snapshot_overlay_files(String.t(), String.t()) :: %{String.t() => binary()}
  defp snapshot_overlay_files(project_root, overlay_dir) do
    collect_snapshot_files(project_root, overlay_dir, "", %{})
  end

  @spec baseline_overlay_files(String.t(), String.t()) :: %{String.t() => binary()}
  defp baseline_overlay_files(project_root, overlay_dir) do
    collect_baseline_files(project_root, overlay_dir, "", %{})
  end

  @spec collect_snapshot_files(String.t(), String.t(), String.t(), %{String.t() => binary()}) ::
          %{String.t() => binary()}
  defp collect_snapshot_files(dir, overlay_dir, rel_prefix, acc) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, acc, &collect_snapshot_entry(dir, overlay_dir, rel_prefix, &1, &2))

      {:error, _} ->
        acc
    end
  end

  @spec collect_snapshot_entry(String.t(), String.t(), String.t(), String.t(), %{
          String.t() => binary()
        }) ::
          %{String.t() => binary()}
  defp collect_snapshot_entry(dir, overlay_dir, rel_prefix, entry, acc) do
    collect_project_entry(
      dir,
      overlay_dir,
      rel_prefix,
      entry,
      acc,
      &put_snapshot_entry/3,
      &collect_snapshot_files/4
    )
  end

  @spec collect_baseline_files(String.t(), String.t(), String.t(), %{String.t() => binary()}) ::
          %{String.t() => binary()}
  defp collect_baseline_files(dir, overlay_dir, rel_prefix, acc) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, acc, &collect_baseline_entry(dir, overlay_dir, rel_prefix, &1, &2))

      {:error, _} ->
        acc
    end
  end

  @spec collect_baseline_entry(String.t(), String.t(), String.t(), String.t(), %{
          String.t() => binary()
        }) ::
          %{String.t() => binary()}
  defp collect_baseline_entry(dir, overlay_dir, rel_prefix, entry, acc) do
    collect_project_entry(
      dir,
      overlay_dir,
      rel_prefix,
      entry,
      acc,
      &put_baseline_entry/3,
      &collect_baseline_files/4
    )
  end

  @spec collect_project_entry(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          %{String.t() => binary()},
          (String.t(), String.t(), %{String.t() => binary()} -> %{String.t() => binary()}),
          (String.t(), String.t(), String.t(), %{String.t() => binary()} ->
             %{String.t() => binary()})
        ) :: %{String.t() => binary()}
  defp collect_project_entry(dir, overlay_dir, rel_prefix, entry, acc, put_fun, descend_fun) do
    if MapSet.member?(@skip_dirs, entry) do
      acc
    else
      collect_project_path(dir, overlay_dir, rel_prefix, entry, acc, put_fun, descend_fun)
    end
  end

  @spec collect_project_path(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          %{String.t() => binary()},
          (String.t(), String.t(), %{String.t() => binary()} -> %{String.t() => binary()}),
          (String.t(), String.t(), String.t(), %{String.t() => binary()} ->
             %{String.t() => binary()})
        ) :: %{String.t() => binary()}
  defp collect_project_path(dir, overlay_dir, rel_prefix, entry, acc, put_fun, descend_fun) do
    path = Path.join(dir, entry)
    rel_path = relative_entry_path(rel_prefix, entry)

    case File.lstat(path) do
      {:ok, %{type: :regular}} -> put_fun.(overlay_dir, rel_path, acc)
      {:ok, %{type: :directory}} -> descend_fun.(path, overlay_dir, rel_path, acc)
      _ -> acc
    end
  end

  @spec put_snapshot_entry(String.t(), String.t(), %{String.t() => binary()}) :: %{
          String.t() => binary()
        }
  defp put_snapshot_entry(overlay_dir, rel_path, acc) do
    case file_signature(Path.join(overlay_dir, rel_path)) do
      {:ok, signature} -> Map.put(acc, rel_path, signature)
      {:error, _} -> acc
    end
  end

  @spec put_baseline_entry(String.t(), String.t(), %{String.t() => binary()}) :: %{
          String.t() => binary()
        }
  defp put_baseline_entry(overlay_dir, rel_path, acc) do
    case File.read(Path.join(overlay_dir, rel_path)) do
      {:ok, content} -> Map.put(acc, rel_path, content)
      {:error, _} -> acc
    end
  end

  @spec file_signature(String.t()) :: {:ok, binary()} | {:error, term()}
  defp file_signature(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, file_signature_from_content(content)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec file_signature_from_content(binary()) :: binary()
  defp file_signature_from_content(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  @spec file_size(String.t()) :: non_neg_integer()
  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> 0
    end
  end

  @spec tracked_entries(state()) :: [map()]
  defp tracked_entries(state) do
    state
    |> tracked_paths()
    |> Enum.flat_map(&tracked_entry(state, &1))
  end

  @spec tracked_paths(state()) :: [String.t()]
  defp tracked_paths(state) do
    state.modifications
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.union(state.deletions)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  @spec tracked_entry(state(), String.t()) :: [map()]
  defp tracked_entry(state, path) do
    case current_overlay_state(state, path) do
      {:ok, content} -> [tracked_content_entry(state, path, content)]
      :deleted -> [%{path: path, kind: :deleted, size: 0}]
      {:error, _reason} -> []
    end
  end

  @spec tracked_content_entry(state(), String.t(), binary()) :: map()
  defp tracked_content_entry(state, path, content) do
    kind = if Map.has_key?(state.originals, path), do: :modified, else: :new
    %{path: path, kind: kind, size: byte_size(content)}
  end

  @spec tracked_path?(state(), String.t()) :: boolean()
  defp tracked_path?(%{modifications: modifications, deletions: deletions}, path) do
    Map.has_key?(modifications, path) or MapSet.member?(deletions, path)
  end

  @spec normalize_path(state(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_traversal}
  defp normalize_path(state, path) do
    root = Path.expand(state.project_root)
    target = Path.join(root, path) |> Path.expand()

    normalize_target(root, target)
  end

  @spec normalize_target(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_traversal}
  defp normalize_target(root, root), do: {:error, :invalid_path}

  defp normalize_target(root, target) do
    if String.starts_with?(target, root <> "/") do
      {:ok, Path.relative_to(target, root)}
    else
      {:error, :path_traversal}
    end
  end

  @spec broadcast_merged(state()) :: :ok
  defp broadcast_merged(state) do
    modified = state.modifications |> Map.keys() |> Enum.sort()
    deleted = state.deletions |> MapSet.to_list() |> Enum.sort()

    Minga.Events.broadcast(
      :changeset_merged,
      %MergedEvent{
        project_root: state.project_root,
        modified: modified,
        deleted: deleted
      }
    )
  end
end
