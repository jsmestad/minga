# credo:disable-for-this-file Credo.Check.Refactor.Nesting
# credo:disable-for-this-file Credo.Check.Readability.WithSingleClause

defmodule MingaAgent.Changeset.Server do
  @moduledoc """
  GenServer managing a single changeset's lifecycle.

  Holds modified file contents in memory and keeps the overlay directory
  in sync. Maintains an edit history per file for undo support.
  Integrates three-way merge via `Minga.Core.Diff.merge3/3`.
  """

  use GenServer, restart: :temporary

  alias Minga.Buffer.Document
  alias Minga.Buffer.Replace
  alias Minga.Core.Overlay
  alias MingaAgent.Changeset.MergedEvent

  @tombstone_suffix ".__changeset_deleted__"

  @typedoc "Internal server state."
  @type state :: %{
          project_root: String.t(),
          overlay: Overlay.t(),
          modifications: %{String.t() => binary()},
          originals: %{String.t() => binary()},
          deletions: MapSet.t(String.t()),
          history: %{String.t() => [binary() | :unmodified | :deleted]},
          budget: pos_integer() | :unlimited,
          attempts: non_neg_integer()
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
          modifications: %{},
          originals: %{},
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
        was_deleted = MapSet.member?(state.deletions, path)

        with :ok <- clear_deleted_marker(state, path, was_deleted),
             :ok <- Overlay.materialize_file(state.overlay, path, content) do
          state = capture_original(state, path)
          state = push_history(state, path)
          state = put_in(state.modifications[path], content)
          state = %{state | deletions: MapSet.delete(state.deletions, path)}
          {:reply, :ok, state}
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
        case Overlay.delete_file(state.overlay, path) do
          :ok ->
            state = capture_original(state, path)
            state = push_history(state, path)
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
    modified = state.modifications |> Map.keys() |> Enum.sort()
    deleted = state.deletions |> MapSet.to_list() |> Enum.sort()
    {:reply, %{modified: modified, deleted: deleted}, state}
  end

  def handle_call(:summary, _from, state) do
    modified =
      Enum.map(state.modifications, fn {path, content} ->
        kind = if Map.has_key?(state.originals, path), do: :modified, else: :new
        %{path: path, kind: kind, size: byte_size(content)}
      end)

    deleted =
      Enum.map(state.deletions, fn path ->
        %{path: path, kind: :deleted, size: 0}
      end)

    {:reply, Enum.sort_by(modified ++ deleted, & &1.path), state}
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
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:discard_file, relative_path}, _from, state) do
    case normalize_path(state, relative_path) do
      {:ok, path} ->
        case {tracked_path?(state, path), discard_file_cleanup(state, path)} do
          {true, :ok} ->
            state = %{
              state
              | modifications: Map.delete(state.modifications, path),
                originals: Map.delete(state.originals, path),
                deletions: MapSet.delete(state.deletions, path),
                history: Map.delete(state.history, path)
            }

            {:reply, :ok, state}

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
    :ok = apply_plans(plans)

    case conflict_details(plans) do
      nil ->
        Overlay.cleanup(state.overlay)
        broadcast_merged(state)
        {:stop, :normal, :ok, state}

      details ->
        state = prune_successful_merge_results(state, details.results)
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
  @typep merge_action :: {:write, String.t(), binary()} | {:rm, String.t()} | :noop
  @typep merge_plan :: {result :: tuple(), merge_action()}

  # Plans the full merge without touching disk. Returns one plan per file; the
  # caller decides whether to apply the write actions (`:merge`) or discard them
  # (`:preflight_merge`). Planning is fully write-free so both paths can share it.
  @spec plan_merge(state()) :: [merge_plan()]
  defp plan_merge(state) do
    modification_plans =
      Enum.map(state.modifications, fn {path, changeset_content} ->
        plan_one_file(state, path, changeset_content)
      end)

    deletion_plans =
      Enum.map(state.deletions, fn path ->
        plan_one_deletion(state, path)
      end)

    modification_plans ++ deletion_plans
  end

  # Builds the conflict report (matching `merge/1`'s shape) from a plan list, or
  # `nil` when every file would merge cleanly.
  @spec conflict_details([merge_plan()]) :: map() | nil
  defp conflict_details(plans) do
    all_results = results_from_plans(plans)
    conflicts = Enum.filter(all_results, &match?({:conflict, _, _}, &1))

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
  @spec apply_plans([merge_plan()]) :: :ok
  defp apply_plans(plans) do
    Enum.each(plans, fn {_result, action} -> apply_merge_action(action) end)
  end

  @spec apply_merge_action(merge_action()) :: :ok
  defp apply_merge_action({:write, real_path, content}) do
    File.mkdir_p!(Path.dirname(real_path))
    File.write!(real_path, content)
  end

  defp apply_merge_action({:rm, real_path}), do: File.rm!(real_path)
  defp apply_merge_action(:noop), do: :ok

  @spec prune_successful_merge_results(state(), [tuple()]) :: state()
  defp prune_successful_merge_results(state, results) do
    Enum.reduce(results, state, &prune_successful_merge_result/2)
  end

  @spec prune_successful_merge_result(tuple(), state()) :: state()
  defp prune_successful_merge_result({:ok, path, _kind}, state) do
    %{
      state
      | modifications: Map.delete(state.modifications, path),
        originals: Map.delete(state.originals, path),
        deletions: MapSet.delete(state.deletions, path),
        history: Map.delete(state.history, path)
    }
  end

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
    {{:ok, path, :created}, {:write, real_path, changeset_content}}
  end

  # New file but someone else also created it
  defp plan_strategy(_real_path, path, nil = _original, _current_real, _changeset_content) do
    {{:conflict, path, :both_created}, :noop}
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

  @spec undo_path(String.t(), state()) :: {:reply, :ok | {:error, term()}, state()}
  defp undo_path(path, state) do
    case Map.get(state.history, path) do
      [prev | rest] ->
        case prev do
          :unmodified ->
            case restore_original(state, path) do
              :ok ->
                state = put_in(state.history[path], rest)
                state = %{state | modifications: Map.delete(state.modifications, path)}
                state = %{state | deletions: MapSet.delete(state.deletions, path)}
                {:reply, :ok, state}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end

          :deleted ->
            case restore_deleted_overlay(state, path) do
              :ok ->
                state = put_in(state.history[path], rest)
                state = %{state | modifications: Map.delete(state.modifications, path)}
                state = %{state | deletions: MapSet.put(state.deletions, path)}
                {:reply, :ok, state}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end

          prev ->
            case Overlay.materialize_file(state.overlay, path, prev) do
              :ok ->
                state = put_in(state.history[path], rest)
                state = put_in(state.modifications[path], prev)
                state = %{state | deletions: MapSet.delete(state.deletions, path)}
                {:reply, :ok, state}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end
        end

      _ ->
        {:reply, {:error, :nothing_to_undo}, state}
    end
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
        :ok -> {:ok, put_in(state.modifications[path], new_content)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec current_content(state(), String.t()) :: {:ok, binary()} | {:error, term()}
  defp current_content(state, path) do
    case {MapSet.member?(state.deletions, path), Map.fetch(state.modifications, path)} do
      {true, _} -> {:error, :deleted}
      {_, {:ok, content}} -> {:ok, content}
      {_, :error} -> File.read(Path.join(state.project_root, path))
    end
  end

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
    current =
      case {MapSet.member?(state.deletions, path), Map.fetch(state.modifications, path)} do
        {true, _} -> :deleted
        {false, {:ok, content}} -> content
        {false, :error} -> :unmodified
      end

    history = Map.get(state.history, path, [])
    put_in(state.history[path], [current | history])
  end

  @spec clear_deleted_marker(state(), String.t(), boolean()) :: :ok | {:error, term()}
  defp clear_deleted_marker(_state, _path, false), do: :ok

  defp clear_deleted_marker(state, path, true) do
    remove_overlay_artifact(
      Path.join(state.overlay.overlay_dir, path) <> ".__changeset_deleted__"
    )
  end

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
  defp discard_file_cleanup(state, path) do
    overlay_path = Path.join(state.overlay.overlay_dir, path)
    project_path = Path.join(state.project_root, path)
    tombstone_path = overlay_path <> ".__changeset_deleted__"
    backup_path = overlay_path <> ".__discard_backup__"

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
    case restore_discarded_overlay_content(state, path) do
      :ok -> restore_discarded_tombstone(state, path, tombstone_path)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec restore_discarded_overlay_content(state(), String.t()) :: :ok | {:error, term()}
  defp restore_discarded_overlay_content(state, path) do
    if Map.has_key?(state.modifications, path) do
      case Map.fetch(state.modifications, path) do
        {:ok, content} ->
          case Overlay.materialize_file(state.overlay, path, content) do
            :ok -> :ok
            {:error, reason} -> {:error, {:materialize_failed, reason}}
          end

        :error ->
          :ok
      end
    else
      :ok
    end
  end

  @spec restore_discarded_tombstone(state(), String.t(), String.t()) :: :ok | {:error, term()}
  defp restore_discarded_tombstone(state, path, tombstone_path) do
    if MapSet.member?(state.deletions, path) do
      with :ok <- File.mkdir_p(Path.dirname(tombstone_path)),
           :ok <- File.write(tombstone_path, "") do
        :ok
      else
        {:error, reason} -> {:error, {:tombstone_restore_failed, reason}}
      end
    else
      :ok
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

  @spec restore_original(state(), String.t()) :: :ok | {:error, term()}
  defp restore_original(state, path) do
    overlay_path = Path.join(state.overlay.overlay_dir, path)
    project_path = Path.join(state.project_root, path)
    tombstone_path = overlay_path <> ".__changeset_deleted__"
    backup_path = overlay_path <> ".__restore_backup__"

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
    paths =
      state.modifications
      |> Map.keys()
      |> Kernel.++(MapSet.to_list(state.deletions))
      |> Enum.uniq()
      |> Enum.sort()

    restore_all(paths, state)
  end

  @spec restore_all([String.t()], state()) :: {:ok, state()} | {:error, term(), state()}
  defp restore_all([], state), do: {:ok, state}

  defp restore_all([path | rest], state) do
    case restore_original(state, path) do
      :ok -> restore_all(rest, forget_restored_path(state, path))
      {:error, reason} -> {:error, reason, state}
    end
  end

  @spec forget_restored_path(state(), String.t()) :: state()
  defp forget_restored_path(state, path) do
    %{
      state
      | modifications: Map.delete(state.modifications, path),
        originals: Map.delete(state.originals, path),
        deletions: MapSet.delete(state.deletions, path),
        history: Map.delete(state.history, path)
    }
  end

  @spec tracked_path?(state(), String.t()) :: boolean()
  defp tracked_path?(state, path) do
    Map.has_key?(state.modifications, path) or Map.has_key?(state.originals, path) or
      MapSet.member?(state.deletions, path) or Map.has_key?(state.history, path)
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
