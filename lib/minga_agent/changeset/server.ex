# credo:disable-for-this-file Credo.Check.Refactor.Nesting
# credo:disable-for-this-file Credo.Check.Readability.WithSingleClause

defmodule MingaAgent.Changeset.Server do
  @moduledoc """
  GenServer managing a single changeset's lifecycle.

  Tracks pending file contents and deletions in memory and keeps the overlay
  directory in sync. Maintains an edit history per file for undo support.
  Integrates three-way merge via `Minga.Core.Diff.merge3/3`.
  """

  use GenServer, restart: :temporary

  alias Minga.Buffer.Document
  alias Minga.Buffer.FileMutation
  alias Minga.Buffer.Persistence.LocalWriter
  alias Minga.Buffer.Persistence.SystemFileSystem
  alias Minga.Buffer.Replace
  alias Minga.Session.StagedDraft
  alias MingaAgent.Changeset.MergedEvent
  alias MingaAgent.Changeset.Overlay
  alias MingaAgent.Changeset.SourceRead

  @tombstone_suffix ".__changeset_deleted__"

  @typep pending_change :: binary() | :deleted
  @typep change :: pending_change() | :unmodified

  @typedoc "Internal server state."
  @type state :: %{
          project_root: String.t(),
          overlay: Overlay.t(),
          changes: %{String.t() => pending_change()},
          originals: %{String.t() => binary() | nil},
          history: %{String.t() => [change()]},
          budget: pos_integer() | :unlimited,
          attempts: non_neg_integer(),
          revision: non_neg_integer(),
          publication: {module(), keyword()},
          observer: pid() | nil,
          staging: {atom(), term()} | nil
        }

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
        state = %{
          project_root: project_root,
          overlay: overlay,
          changes: %{},
          originals: %{},
          history: %{},
          budget: budget,
          attempts: 0,
          revision: 0,
          publication: {
            Keyword.get(opts, :publication_file_system, SystemFileSystem),
            Keyword.get(opts, :publication_opts, [])
          },
          observer: nil,
          staging: nil
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
        with :ok <- clear_deleted_marker(state, path, current_change(state, path)),
             :ok <- Overlay.materialize_file(state.overlay, path, content) do
          state = capture_original(state, path)
          state = push_history(state, path)
          state = install_mutation(state, path, content)
          {:reply, :ok, bump_revision(state)}
        else
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
          {:ok, new_state} -> {:reply, :ok, bump_revision(new_state)}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete_file, relative_path}, _from, state) do
    case normalize_path(state, relative_path) do
      {:ok, path} ->
        case Overlay.delete_file(state.overlay, path) do
          :ok ->
            state = capture_original(state, path)
            state = push_history(state, path)
            state = install_mutation(state, path, :deleted)
            {:reply, :ok, bump_revision(state)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:conditional_mutate, relative_path, expected, operation, identity},
        _from,
        state
      ) do
    with {:ok, path} <- normalize_path(state, relative_path),
         source = mutation_source(state, path),
         {:ok, prepared} <-
           FileMutation.prepare(
             source,
             mutation_generation(state, identity),
             identity,
             expected,
             operation
           ),
         :ok <- Overlay.commit_file(state.overlay, path, prepared) do
      state =
        state
        |> remember_original(path, source)
        |> push_history(path)
        |> install_mutation(path, prepared)
        |> bump_revision()

      {:reply, {:ok, FileMutation.Receipt.committed(source, prepared)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:capture_original, relative_path}, _from, state) do
    with {:ok, path} <- normalize_path(state, relative_path) do
      case File.read(Path.join(state.project_root, path)) do
        {:ok, _} = source -> {:reply, :ok, remember_original(state, path, source)}
        {:error, :enoent} = source -> {:reply, :ok, remember_original(state, path, source)}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stage_fork_content, relative_path, content}, _from, state) do
    with {:ok, path} <- normalize_path(state, relative_path),
         true <- Map.has_key?(state.originals, path),
         :ok <- Overlay.commit_file(state.overlay, path, content) do
      state =
        state
        |> push_history(path)
        |> install_mutation(path, content)
        |> bump_revision()

      {:reply, :ok, state}
    else
      false -> {:reply, {:error, :publication_baseline_unavailable}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stage_fork_resolution, relative_path, ancestor, selected}, _from, state) do
    with {:ok, path} <- normalize_path(state, relative_path),
         :ok <- require_publication_baseline(state, path) do
      stage_fork_resolution(state, path, ancestor, selected)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:publish_deletion, relative_path}, _from, state) do
    with {:ok, path} <- normalize_path(state, relative_path),
         true <- Map.has_key?(state.originals, path) do
      case plan_one_deletion(state, path) do
        {{:ok, _, _} = result, action} ->
          case apply_merge_action(action, state.publication) do
            :ok ->
              state = prune_successful_merge_result(result, state)
              {:reply, :ok, bump_revision(state)}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end

        {result, :noop} ->
          {:reply, {:conflict, %{conflicts: [result], results: [result]}}, state}
      end
    else
      false -> {:reply, {:error, :publication_baseline_unavailable}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  rescue
    error -> {:reply, {:error, Exception.message(error)}, state}
  end

  def handle_call({:materialize_command_deletion, relative_path}, _from, state) do
    result =
      with {:ok, path} <- normalize_path(state, relative_path) do
        Overlay.commit_file(state.overlay, path, :deleted)
      end

    {:reply, result, state}
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

  def handle_call({:read_file_with_version, relative_path}, _from, state) do
    case normalize_path(state, relative_path) do
      {:ok, path} ->
        case current_content(state, path) do
          {:ok, content} -> {:reply, {:ok, content, state.revision}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:read_source_prefix_with_version, relative_path, max_bytes}, _from, state) do
    source =
      with {:ok, path} <- normalize_path(state, relative_path), do: source_descriptor(state, path)

    {:reply, SourceRead.prefix(source, state.revision, max_bytes), state}
  end

  def handle_call(
        {:read_source_lines_with_version, relative_path, start, count, max_bytes},
        _from,
        state
      ) do
    source =
      with {:ok, path} <- normalize_path(state, relative_path), do: source_descriptor(state, path)

    {:reply, SourceRead.lines(source, state.revision, start, count, max_bytes), state}
  end

  def handle_call({:observe, observer, registration}, _from, state) do
    case join_staging(state.staging, registration) do
      :ok -> {:reply, :ok, %{state | observer: observer, staging: registration}}
      {:error, _reason} = error -> {:reply, error, %{state | observer: observer}}
    end
  end

  def handle_call(:staging, _from, state) do
    {:reply, staging_value(state.staging), state}
  end

  def handle_call({:staged_drafts, baseline_paths}, _from, state) do
    drafts =
      state.changes
      |> Enum.sort_by(fn {path, _change} -> path end)
      |> Enum.map(fn {path, change} ->
        StagedDraft.new(path, Map.get(state.originals, path), change)
      end)

    {:reply, {drafts, Map.take(state.originals, baseline_paths)}, state}
  end

  def handle_call({:restore_draft, %StagedDraft{} = draft}, _from, state) do
    with {:ok, path} <- normalize_path(state, draft.path),
         :ok <- Overlay.commit_file(state.overlay, path, draft.content) do
      state =
        %{state | originals: Map.put(state.originals, path, draft.base)}
        |> install_mutation(path, draft.content)
        |> bump_revision()

      {:reply, :ok, state}
    else
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

  def handle_call(:materialize_for_command, _from, state) do
    {:reply, Overlay.materialize_project(state.overlay), state}
  end

  def handle_call({:materialize_command_file, relative_path, content}, _from, state) do
    case normalize_path(state, relative_path) do
      {:ok, path} -> {:reply, Overlay.materialize_file(state.overlay, path, content), state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:list_directory, relative_path}, _from, state) do
    case normalize_path_allow_root(state, relative_path) do
      {:ok, path} -> {:reply, Overlay.list_directory(state.overlay, path), state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:modified_files, _from, state) do
    {modified, deleted} = changed_paths(state.changes)
    {:reply, %{modified: modified, deleted: deleted}, state}
  end

  def handle_call(:summary, _from, state) do
    summary =
      Enum.map(state.changes, fn
        {path, :deleted} ->
          %{path: path, kind: :deleted, size: 0}

        {path, content} ->
          kind = if is_binary(Map.get(state.originals, path)), do: :modified, else: :new
          %{path: path, kind: kind, size: byte_size(content)}
      end)

    {:reply, Enum.sort_by(summary, & &1.path), state}
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
    case restore_all(state) do
      {:ok, new_state} ->
        {:reply, :ok, bump_revision(new_state)}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, bump_if_sources_changed(new_state, state)}
    end
  end

  def handle_call({:discard_file, relative_path}, _from, state) do
    case normalize_path(state, relative_path) do
      {:ok, path} ->
        case {tracked_path?(state, path), discard_file_cleanup(state, path)} do
          {true, :ok} ->
            state = forget_path(state, path)

            {:reply, :ok, bump_revision(state)}

          {true, {:error, reason}} ->
            {:reply, {:error, reason}, state}

          {false, _cleanup_result} ->
            {:reply, :ok, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:merge, _from, state) do
    plans = plan_merge(state)

    # Apply every clean per-file plan, even on a partial conflict. Files that
    # merged cleanly are written and pruned so a later retry skips them.
    results = apply_plans(plans, state.publication)

    case merge_result_details(results) do
      nil ->
        Overlay.cleanup(state.overlay)
        broadcast_merged(state)
        {:stop, :normal, :ok, state}

      details ->
        state =
          state
          |> prune_successful_merge_results(details.results)
          |> bump_if_sources_changed(state)

        {:reply, {:conflict, details}, state}
    end
  rescue
    e ->
      {:reply, {:error, Exception.message(e)}, state}
  end

  def handle_call(:preflight_merge, _from, state) do
    plans = plan_merge(state)

    case conflict_details(plans) do
      nil -> {:reply, {:ok, results_from_plans(plans)}, state}
      details -> {:reply, {:conflict, details}, state}
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

  # A per-file merge plan pairs the decision result tuple with the disk action
  # that `:merge` performs to realize it. `:preflight_merge` keeps the results
  # and discards the actions, so planning is fully write-free and reusable.
  @typep merge_action ::
           {:write | :create, String.t(), binary()} | {:rm, String.t()} | :noop
  @typep merge_plan :: {result :: tuple(), merge_action()}

  # Plans the full merge without touching disk. Returns one plan per file; the
  # caller decides whether to apply the write actions (`:merge`) or discard them
  # (`:preflight_merge`). Planning is fully write-free so both paths can share it.
  @spec plan_merge(state()) :: [merge_plan()]
  defp plan_merge(state) do
    # Plan modifications first so their disk reads precede deletion planning.
    modification_plans =
      for {path, content} <- state.changes, is_binary(content) do
        plan_one_file(state, path, content)
      end

    deletion_plans =
      for {path, :deleted} <- state.changes do
        plan_one_deletion(state, path)
      end

    modification_plans ++ deletion_plans
  end

  # Builds the conflict report (matching `merge/1`'s shape) from a plan list, or
  # `nil` when every file would merge cleanly.
  @spec conflict_details([merge_plan()]) :: map() | nil
  defp conflict_details(plans) do
    merge_result_details(results_from_plans(plans))
  end

  @spec merge_result_details([tuple()]) :: map() | nil
  defp merge_result_details(all_results) do
    conflicts = Enum.reject(all_results, &match?({:ok, _, _}, &1))

    if conflicts == [] do
      nil
    else
      %{conflicts: conflicts, results: all_results}
    end
  end

  @spec results_from_plans([merge_plan()]) :: [tuple()]
  defp results_from_plans(plans), do: Enum.map(plans, fn {result, _action} -> result end)

  # Performs the disk writes for the clean plans. Only reached from `:merge`.
  # Conflict plans carry a `:noop` action, so partial merges write only the
  # files that merged cleanly and leave conflicting files on disk untouched.
  @spec apply_plans([merge_plan()], {module(), keyword()}) :: [tuple()]
  defp apply_plans(plans, publication) do
    Enum.map(plans, fn {result, action} ->
      case apply_merge_action(action, publication) do
        :ok -> result
        {:error, reason} -> {:error, elem(result, 1), reason}
      end
    end)
  end

  @spec apply_merge_action(merge_action(), {module(), keyword()}) :: :ok | {:error, term()}
  defp apply_merge_action({:write, real_path, content}, {file_system, opts}) do
    LocalWriter.write(real_path, content, :replace, file_system, opts)
  end

  defp apply_merge_action({:create, real_path, content}, {file_system, opts}) do
    LocalWriter.write(real_path, content, :exclusive_create, file_system, opts)
  end

  defp apply_merge_action({:rm, real_path}, {file_system, opts}),
    do: file_system.remove(real_path, opts)

  defp apply_merge_action(:noop, _publication), do: :ok

  @spec prune_successful_merge_results(state(), [tuple()]) :: state()
  defp prune_successful_merge_results(state, results) do
    Enum.reduce(results, state, &prune_successful_merge_result/2)
  end

  @spec prune_successful_merge_result(tuple(), state()) :: state()
  defp prune_successful_merge_result({:ok, path, _kind}, state), do: forget_path(state, path)

  defp prune_successful_merge_result(_result, state), do: state

  @spec plan_one_file(state(), String.t(), binary()) :: merge_plan()
  defp plan_one_file(state, path, changeset_content) do
    real_path = Path.join(state.project_root, path)
    original = Map.get(state.originals, path)

    current_real =
      case File.read(real_path) do
        {:ok, c} -> c
        {:error, :enoent} -> nil
      end

    plan_strategy(real_path, path, original, current_real, changeset_content)
  end

  # New file: didn't exist when changeset was created
  @spec plan_strategy(String.t(), String.t(), binary() | nil, binary() | nil, binary()) ::
          merge_plan()
  defp plan_strategy(real_path, path, nil = _original, nil = _current_real, changeset_content) do
    {{:ok, path, :created}, {:create, real_path, changeset_content}}
  end

  # New file but someone else also created it
  defp plan_strategy(_real_path, path, nil = _original, _current_real, _changeset_content) do
    {{:conflict, path, :both_created}, :noop}
  end

  defp plan_strategy(_real_path, path, _original, nil, _changeset_content) do
    {{:conflict, path, :deleted_before_publish}, :noop}
  end

  # Real file unchanged since changeset was created: apply directly
  defp plan_strategy(real_path, path, original, current_real, changeset_content)
       when current_real == original do
    {{:ok, path, :applied}, {:write, real_path, changeset_content}}
  end

  # Real file was also modified: three-way merge
  defp plan_strategy(real_path, path, original, current_real, changeset_content) do
    ancestor_lines = String.split(original, "\n", trim: false)
    ours_lines = String.split(changeset_content, "\n", trim: false)
    theirs_lines = String.split(current_real, "\n", trim: false)

    case Minga.Core.Diff.merge3(ancestor_lines, ours_lines, theirs_lines) do
      {:ok, merged_lines} ->
        {{:ok, path, :merged_three_way}, {:write, real_path, Enum.join(merged_lines, "\n")}}

      {:conflict, _hunks} ->
        {{:conflict, path, :concurrent_edit}, :noop}
    end
  end

  @spec plan_one_deletion(state(), String.t()) :: merge_plan()
  defp plan_one_deletion(state, path) do
    real_path = Path.join(state.project_root, path)
    original = Map.get(state.originals, path)

    case File.read(real_path) do
      {:ok, content} when content == original ->
        {{:ok, path, :deleted}, {:rm, real_path}}

      {:ok, _changed} ->
        {{:conflict, path, :modified_before_delete}, :noop}

      {:error, :enoent} ->
        {{:ok, path, :already_deleted}, :noop}
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec mutation_generation(state(), FileMutation.identity()) :: non_neg_integer() | nil
  defp mutation_generation(_state, {:project_view, _}), do: nil
  defp mutation_generation(state, _identity), do: state.revision

  @spec stage_fork_resolution(state(), String.t(), String.t(), String.t()) ::
          {:reply, :ok | {:error, term()}, state()}
  defp stage_fork_resolution(state, path, content, content) do
    {:reply, reconcile_fork_overlay(state, path), state}
  end

  defp stage_fork_resolution(state, path, ancestor, selected) do
    with {:ok, baseline} <- fork_staging_baseline(state, path),
         {:ok, content} <- resolve_fork_staging(ancestor, selected, baseline) do
      case content do
        ^baseline ->
          {:reply, reconcile_fork_overlay(state, path), state}

        content ->
          case Overlay.commit_file(state.overlay, path, content) do
            :ok ->
              state =
                state |> push_history(path) |> install_mutation(path, content) |> bump_revision()

              {:reply, :ok, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
      end
    else
      {:conflict, _} -> {:reply, {:error, :publication_baseline_conflict}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @spec require_publication_baseline(state(), String.t()) :: :ok | {:error, atom()}
  defp require_publication_baseline(state, path) do
    if Map.has_key?(state.originals, path),
      do: :ok,
      else: {:error, :publication_baseline_unavailable}
  end

  @spec fork_staging_baseline(state(), String.t()) ::
          {:ok, binary() | :missing} | {:error, :deleted}
  defp fork_staging_baseline(state, path) do
    case current_change(state, path) do
      :deleted -> {:error, :deleted}
      :unmodified -> {:ok, Map.fetch!(state.originals, path) || :missing}
      content -> {:ok, content}
    end
  end

  @spec resolve_fork_staging(binary(), binary(), binary() | :missing) ::
          {:ok, binary() | :missing} | {:conflict, term()}
  defp resolve_fork_staging(ancestor, selected, :missing) do
    # A final newline must not attribute an unchanged human line to the fork.
    additions =
      for {:ins, lines} <- List.myers_difference(staging_lines(ancestor), staging_lines(selected)),
          line <- lines,
          do: line

    case additions do
      [] ->
        {:ok, :missing}

      lines ->
        ending = if String.ends_with?(selected, "\n"), do: "\n", else: ""
        {:ok, Enum.join(lines, "\n") <> ending}
    end
  end

  defp resolve_fork_staging(ancestor, selected, baseline) do
    with {:ok, lines} <-
           Minga.Core.Diff.merge3(
             String.split(ancestor, "\n"),
             String.split(selected, "\n"),
             String.split(baseline, "\n")
           ) do
      {:ok, Enum.join(lines, "\n")}
    end
  end

  @spec staging_lines(binary()) :: [binary()]
  defp staging_lines(""), do: []

  defp staging_lines(content) do
    size = byte_size(content)
    size = if :binary.last(content) == ?\n, do: size - 1, else: size
    :binary.split(binary_part(content, 0, size), "\n", [:global])
  end

  @spec reconcile_fork_overlay(state(), String.t()) :: :ok | {:error, term()}
  defp reconcile_fork_overlay(state, path) do
    case current_change(state, path) do
      :unmodified -> restore_original(state, path)
      change -> Overlay.commit_file(state.overlay, path, change)
    end
  end

  @spec mutation_source(state(), String.t()) :: FileMutation.source()
  defp mutation_source(state, path) do
    case current_content(state, path) do
      {:error, :deleted} -> {:error, :enoent}
      source -> source
    end
  end

  @spec remember_original(state(), String.t(), FileMutation.source()) :: state()
  defp remember_original(state, path, {:ok, content}) do
    %{state | originals: Map.put_new(state.originals, path, content)}
  end

  defp remember_original(state, path, {:error, _}) do
    %{state | originals: Map.put_new(state.originals, path, nil)}
  end

  @spec install_mutation(state(), String.t(), change()) :: state()
  defp install_mutation(state, path, :unmodified) do
    %{state | changes: Map.delete(state.changes, path)}
  end

  defp install_mutation(state, path, change) do
    %{state | changes: Map.put(state.changes, path, change)}
  end

  @spec undo_path(String.t(), state()) :: {:reply, :ok | {:error, term()}, state()}
  defp undo_path(path, state) do
    case Map.get(state.history, path) do
      [previous | rest] ->
        case restore_undo_overlay(state, path, previous) do
          :ok ->
            state = put_in(state.history[path], rest)
            state = install_mutation(state, path, previous)
            {:reply, :ok, bump_revision(state)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _ ->
        {:reply, {:error, :nothing_to_undo}, state}
    end
  end

  @spec restore_undo_overlay(state(), String.t(), change()) :: :ok | {:error, term()}
  defp restore_undo_overlay(state, path, :unmodified), do: restore_original(state, path)
  defp restore_undo_overlay(state, path, :deleted), do: restore_deleted_overlay(state, path)

  defp restore_undo_overlay(state, path, content) when is_binary(content),
    do: Overlay.materialize_file(state.overlay, path, content)

  # Every staged change bumps the revision; the observer (the staged draft
  # keeper) learns that the staged drafts changed and persists them.
  @spec bump_revision(state()) :: state()
  defp bump_revision(state) do
    state = %{state | revision: state.revision + 1}
    notify_observer(state)
    state
  end

  # The changeset outlives its observer, so it carries its own staging
  # registration and announces itself in a `:pg` scope. `:pg` monitors its
  # members instead of linking them, so a failing scope never takes staged
  # edits down with it, and a restarted observer finds every live changeset.
  @spec join_staging({atom(), term()} | nil, {atom(), term()} | nil) :: :ok | {:error, term()}
  defp join_staging(_current, nil), do: :ok
  defp join_staging({scope, _value}, {scope, _new_value}), do: :ok

  defp join_staging(_current, {scope, _value}) do
    :pg.join(scope, :staged_views, self())
  catch
    :error, _reason -> {:error, :staging_scope_unavailable}
  end

  @spec staging_value({atom(), term()} | nil) :: term() | nil
  defp staging_value({_scope, value}), do: value
  defp staging_value(nil), do: nil

  @spec notify_observer(state()) :: :ok
  defp notify_observer(%{observer: observer}) when is_pid(observer) do
    send(observer, {:changeset_revised, self()})
    :ok
  end

  defp notify_observer(_state), do: :ok

  @spec bump_if_sources_changed(state(), state()) :: state()
  defp bump_if_sources_changed(new_state, previous_state) do
    # A failed reset or partial merge can only remove pending changes.
    if map_size(new_state.changes) != map_size(previous_state.changes),
      do: bump_revision(new_state),
      else: new_state
  end

  @spec apply_edit(state(), String.t(), String.t(), String.t()) ::
          {:ok, state()} | {:error, term()}
  defp apply_edit(state, path, old_text, new_text) do
    with {:ok, content} <- current_content(state, path),
         {:ok, edited_doc, _msg} <- Replace.apply(Document.new(content), old_text, new_text, nil) do
      new_content = Document.content(edited_doc)
      state = capture_original(state, path)
      state = push_history(state, path)

      case Overlay.materialize_file(state.overlay, path, new_content) do
        :ok -> {:ok, install_mutation(state, path, new_content)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec source_descriptor(state(), String.t()) ::
          {:ok, {:memory, binary()} | {:disk, String.t()}} | {:error, :deleted}
  defp source_descriptor(state, path) do
    case current_change(state, path) do
      :deleted -> {:error, :deleted}
      :unmodified -> {:ok, {:disk, Path.join(state.project_root, path)}}
      content -> {:ok, {:memory, content}}
    end
  end

  @spec current_content(state(), String.t()) :: {:ok, binary()} | {:error, term()}
  defp current_content(state, path) do
    case current_change(state, path) do
      :deleted -> {:error, :deleted}
      :unmodified -> File.read(Path.join(state.project_root, path))
      content -> {:ok, content}
    end
  end

  @spec current_change(state(), String.t()) :: change()
  defp current_change(state, path), do: Map.get(state.changes, path, :unmodified)

  @spec capture_original(state(), String.t()) :: state()
  defp capture_original(state, path) do
    if Map.has_key?(state.originals, path) do
      state
    else
      case File.read(Path.join(state.project_root, path)) do
        {:ok, content} -> put_in(state.originals[path], content)
        {:error, _} -> state
      end
    end
  end

  @spec push_history(state(), String.t()) :: state()
  defp push_history(state, path) do
    current = current_change(state, path)

    history = Map.get(state.history, path, [])
    put_in(state.history[path], [current | history])
  end

  @spec clear_deleted_marker(state(), String.t(), change()) :: :ok | {:error, term()}
  defp clear_deleted_marker(state, path, :deleted) do
    remove_overlay_artifact(
      Path.join(state.overlay.overlay_dir, path) <> ".__changeset_deleted__"
    )
  end

  defp clear_deleted_marker(_state, _path, _change), do: :ok

  @spec restore_deleted_overlay(state(), String.t()) :: :ok | {:error, term()}
  defp restore_deleted_overlay(state, path) do
    overlay_path = Path.join(state.overlay.overlay_dir, path)
    tombstone_path = overlay_path <> ".__changeset_deleted__"

    with :ok <- remove_overlay_artifact(overlay_path),
         :ok <- File.mkdir_p(Path.dirname(tombstone_path)),
         :ok <- File.write(tombstone_path, "") do
      :ok
    else
      {:error, reason} -> {:error, {:deleted_restore_failed, reason}}
    end
  end

  @spec discard_file_cleanup(state(), String.t()) :: :ok | {:error, term()}
  defp discard_file_cleanup(state, path),
    do: restore_original_with_backup(state, path, ".__discard_backup__")

  @spec restore_original(state(), String.t()) :: :ok | {:error, term()}
  defp restore_original(state, path),
    do: restore_original_with_backup(state, path, ".__restore_backup__")

  @spec restore_original_with_backup(state(), String.t(), String.t()) ::
          :ok | {:error, term()}
  defp restore_original_with_backup(state, path, backup_suffix) do
    overlay_path = Path.join(state.overlay.overlay_dir, path)
    project_path = Path.join(state.project_root, path)
    tombstone_path = overlay_path <> ".__changeset_deleted__"
    backup_path = overlay_path <> backup_suffix

    if File.regular?(project_path) do
      with :ok <- remove_overlay_artifact(backup_path),
           :ok <- remove_overlay_artifact(tombstone_path),
           :ok <- prune_empty_overlay_dirs(state, path),
           :ok <-
             restore_project_file(state.overlay, state.project_root, overlay_path, backup_path),
           :ok <- remove_overlay_artifact(backup_path) do
        :ok
      else
        {:error, reason} ->
          case restore_overlay_backup(overlay_path, backup_path) do
            :ok -> {:error, reason}
            {:error, rollback_reason} -> {:error, {:cleanup_failed, reason, rollback_reason}}
          end
      end
    else
      with :ok <- remove_overlay_artifact(overlay_path),
           :ok <- remove_overlay_artifact(tombstone_path),
           :ok <- prune_empty_overlay_dirs(state, path) do
        :ok
      else
        {:error, reason} ->
          case restore_discarded_overlay(state, path, tombstone_path) do
            :ok -> {:error, reason}
            {:error, rollback_reason} -> {:error, {:cleanup_failed, reason, rollback_reason}}
          end
      end
    end
  end

  @spec restore_discarded_overlay(state(), String.t(), String.t()) :: :ok | {:error, term()}
  defp restore_discarded_overlay(state, path, tombstone_path) do
    case current_change(state, path) do
      :unmodified ->
        :ok

      :deleted ->
        with :ok <- File.mkdir_p(Path.dirname(tombstone_path)),
             :ok <- File.write(tombstone_path, "") do
          :ok
        else
          {:error, reason} -> {:error, {:tombstone_restore_failed, reason}}
        end

      content ->
        case Overlay.materialize_file(state.overlay, path, content) do
          :ok -> :ok
          {:error, reason} -> {:error, {:materialize_failed, reason}}
        end
    end
  end

  @spec remove_overlay_artifact(String.t()) :: :ok | {:error, term()}
  defp remove_overlay_artifact(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec prune_empty_overlay_dirs(state(), String.t()) :: :ok | {:error, term()}
  defp prune_empty_overlay_dirs(state, path) do
    path
    |> Path.dirname()
    |> prune_empty_overlay_dir(state)
  end

  @spec prune_empty_overlay_dir(String.t(), state()) :: :ok | {:error, term()}
  defp prune_empty_overlay_dir(".", _state), do: :ok

  defp prune_empty_overlay_dir(relative_dir, state) do
    overlay_dir = Path.join(state.overlay.overlay_dir, relative_dir)
    project_dir = Path.join(state.project_root, relative_dir)

    if File.dir?(project_dir) do
      :ok
    else
      case File.rmdir(overlay_dir) do
        :ok -> relative_dir |> Path.dirname() |> prune_empty_overlay_dir(state)
        {:error, :enoent} -> relative_dir |> Path.dirname() |> prune_empty_overlay_dir(state)
        {:error, :enotempty} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec restore_project_file(Overlay.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  defp restore_project_file(%Overlay{} = overlay, project_root, overlay_path, backup_path) do
    project_path = Path.join(project_root, Path.relative_to(overlay_path, overlay.overlay_dir))
    temp_path = overlay_path <> ".__restore_tmp__"

    if File.regular?(project_path) do
      with :ok <- remove_overlay_artifact(temp_path),
           :ok <- relink_file(overlay, project_path, temp_path) do
        swap_overlay_with_temp(overlay_path, temp_path, backup_path)
      end
    else
      :ok
    end
  end

  @spec swap_overlay_with_temp(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  defp swap_overlay_with_temp(overlay_path, temp_path, backup_path) do
    if File.exists?(overlay_path) do
      with :ok <- rename_overlay_to_backup(overlay_path, backup_path),
           :ok <- File.rename(temp_path, overlay_path) do
        :ok
      else
        {:error, reason} ->
          case restore_overlay_backup(overlay_path, backup_path) do
            :ok ->
              _ = remove_overlay_artifact(temp_path)
              {:error, reason}

            {:error, rollback_reason} ->
              _ = remove_overlay_artifact(temp_path)
              {:error, {:swap_failed, reason, rollback_reason}}
          end
      end
    else
      case File.rename(temp_path, overlay_path) do
        :ok ->
          :ok

        {:error, reason} ->
          _ = remove_overlay_artifact(temp_path)
          {:error, reason}
      end
    end
  end

  @spec relink_file(Overlay.t(), String.t(), String.t()) :: :ok | {:error, term()}
  defp relink_file(%Overlay{}, source, target) do
    File.cp(source, target)
  end

  @spec rename_overlay_to_backup(String.t(), String.t()) :: :ok | {:error, term()}
  defp rename_overlay_to_backup(path, backup_path) do
    case File.rename(path, backup_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec restore_overlay_backup(String.t(), String.t()) :: :ok | {:error, term()}
  defp restore_overlay_backup(path, backup_path) do
    case File.rename(backup_path, path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec restore_all(state()) :: {:ok, state()} | {:error, term(), state()}
  defp restore_all(state) do
    paths = state.changes |> Map.keys() |> Enum.sort()

    restore_all(paths, state)
  end

  @spec restore_all([String.t()], state()) :: {:ok, state()} | {:error, term(), state()}
  defp restore_all([], state), do: {:ok, state}

  defp restore_all([path | rest], state) do
    case restore_original(state, path) do
      :ok -> restore_all(rest, forget_path(state, path))
      {:error, reason} -> {:error, reason, state}
    end
  end

  @spec forget_path(state(), String.t()) :: state()
  defp forget_path(state, path) do
    %{
      state
      | changes: Map.delete(state.changes, path),
        originals: Map.delete(state.originals, path),
        history: Map.delete(state.history, path)
    }
  end

  @spec tracked_path?(state(), String.t()) :: boolean()
  defp tracked_path?(state, path) do
    Map.has_key?(state.changes, path) or Map.has_key?(state.originals, path) or
      Map.has_key?(state.history, path)
  end

  @spec normalize_path(state(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_traversal}
  defp normalize_path(state, path) do
    with :ok <- reject_tombstone_suffix(path) do
      root = Path.expand(state.project_root)
      target = Path.expand(path, root)

      normalize_target(root, target)
    end
  end

  @spec normalize_path_allow_root(state(), String.t()) ::
          {:ok, String.t()} | {:error, :path_traversal | :invalid_path}
  defp normalize_path_allow_root(state, path) do
    with :ok <- reject_tombstone_suffix(path) do
      root = Path.expand(state.project_root)
      target = Path.expand(path, root)

      normalize_target_allow_root(root, target)
    end
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

  @spec normalize_target_allow_root(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :path_traversal | :invalid_path}
  defp normalize_target_allow_root(root, root), do: {:ok, "."}

  defp normalize_target_allow_root(root, target) do
    if String.starts_with?(target, root <> "/") do
      {:ok, Path.relative_to(target, root)}
    else
      {:error, :path_traversal}
    end
  end

  @spec reject_tombstone_suffix(String.t()) :: :ok | {:error, :invalid_path}
  defp reject_tombstone_suffix(path) do
    if tombstone_component?(Path.split(path)), do: {:error, :invalid_path}, else: :ok
  end

  @spec tombstone_component?([String.t()]) :: boolean()
  defp tombstone_component?(components) do
    Enum.any?(components, &String.ends_with?(&1, @tombstone_suffix))
  end

  @spec changed_paths(%{String.t() => pending_change()}) :: {[String.t()], [String.t()]}
  defp changed_paths(changes) do
    {modified, deleted} =
      Enum.reduce(changes, {[], []}, fn
        {path, :deleted}, {modified, deleted} -> {modified, [path | deleted]}
        {path, _content}, {modified, deleted} -> {[path | modified], deleted}
      end)

    {Enum.sort(modified), Enum.sort(deleted)}
  end

  @spec broadcast_merged(state()) :: :ok
  defp broadcast_merged(state) do
    {modified, deleted} = changed_paths(state.changes)

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
