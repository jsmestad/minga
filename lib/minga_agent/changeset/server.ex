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
  alias MingaAgent.ProjectView.PathResolver

  @typedoc "Internal server state."
  @type state :: %{
          project_root: String.t(),
          overlay: Overlay.t(),
          modifications: %{String.t() => binary()},
          originals: %{String.t() => binary()},
          deletions: MapSet.t(String.t()),
          history: %{String.t() => [binary() | :unmodified]},
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
        case Overlay.materialize_file(state.overlay, path, content) do
          :ok ->
            state = capture_original(state, path)
            state = push_history(state, path)
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
    Enum.each(state.modifications, fn {path, _} ->
      restore_original(state, path)
    end)

    Enum.each(state.deletions, fn path ->
      restore_original(state, path)
    end)

    state = %{state | modifications: %{}, deletions: MapSet.new(), history: %{}}
    {:reply, :ok, state}
  end

  def handle_call(:preflight_merge, _from, state) do
    {:reply, build_merge_plan(state), state}
  end

  def handle_call(:merge, _from, state) do
    case do_merge(state) do
      :ok ->
        Overlay.cleanup(state.overlay)
        broadcast_merged(state)
        {:stop, :normal, :ok, state}

      {:ok, :merged_with_conflicts, details} ->
        Overlay.cleanup(state.overlay)
        broadcast_merged(state)
        {:stop, :normal, {:ok, :merged_with_conflicts, details}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
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

  @spec do_merge(state()) :: :ok | {:ok, :merged_with_conflicts, list()} | {:error, term()}
  defp do_merge(state) do
    with {:ok, plan} <- build_merge_plan(state) do
      apply_merge_plan(plan)
    end
  end

  @spec build_merge_plan(state()) :: {:ok, [map()]} | {:error, term()}
  defp build_merge_plan(state) do
    with {:ok, modification_plans} <- build_modification_plans(state),
         {:ok, deletion_plans} <- build_deletion_plans(state) do
      {:ok, modification_plans ++ deletion_plans}
    end
  end

  @spec build_modification_plans(state()) :: {:ok, [map()]} | {:error, term()}
  defp build_modification_plans(state) do
    state.modifications
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {path, changeset_content}, {:ok, plans} ->
      case plan_merge_one_file(state, path, changeset_content) do
        {:ok, plan} -> {:cont, {:ok, [plan | plans]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, plans} -> {:ok, Enum.reverse(plans)}
      {:error, _} = error -> error
    end
  end

  @spec build_deletion_plans(state()) :: {:ok, [map()]} | {:error, term()}
  defp build_deletion_plans(state) do
    state.deletions
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, plans} ->
      case plan_merge_one_deletion(state, path) do
        {:ok, plan} -> {:cont, {:ok, [plan | plans]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, plans} -> {:ok, Enum.reverse(plans)}
      {:error, _} = error -> error
    end
  end

  @spec plan_merge_one_file(state(), String.t(), binary()) :: {:ok, map()} | {:error, term()}
  defp plan_merge_one_file(state, path, changeset_content) do
    with {:ok, real_path} <- safe_real_path(state, path),
         {:ok, current_real} <- read_current_real(real_path) do
      original = Map.get(state.originals, path)
      plan_merge_action(path, real_path, original, current_real, changeset_content)
    end
  end

  @spec plan_merge_action(String.t(), String.t(), binary() | nil, binary() | nil, binary()) ::
          {:ok, map()}
  defp plan_merge_action(path, real_path, nil, nil, changeset_content) do
    {:ok,
     %{
       kind: :write,
       mkdir_p: true,
       real_path: real_path,
       content: changeset_content,
       result: {path, :ok}
     }}
  end

  defp plan_merge_action(path, _real_path, nil, _current_real, _changeset_content) do
    {:ok, %{kind: :result, result: {path, {:conflict, :both_created}}}}
  end

  defp plan_merge_action(path, real_path, original, current_real, changeset_content)
       when current_real == original and is_binary(original) do
    {:ok,
     %{
       kind: :write,
       mkdir_p: false,
       real_path: real_path,
       content: changeset_content,
       result: {path, :ok}
     }}
  end

  defp plan_merge_action(path, _real_path, original, nil, _changeset_content)
       when is_binary(original) do
    {:ok, %{kind: :result, result: {path, {:conflict, :deleted_before_merge}}}}
  end

  defp plan_merge_action(path, real_path, original, current_real, changeset_content)
       when is_binary(original) and is_binary(current_real) do
    {:ok,
     %{
       kind: :merge3,
       path: path,
       real_path: real_path,
       original: original,
       current_real: current_real,
       content: changeset_content
     }}
  end

  @spec plan_merge_one_deletion(state(), String.t()) :: {:ok, map()} | {:error, term()}
  defp plan_merge_one_deletion(state, path) do
    with {:ok, real_path} <- safe_real_path(state, path),
         {:ok, current_real} <- read_current_real(real_path) do
      original = Map.get(state.originals, path)
      plan_delete_action(path, real_path, original, current_real)
    end
  end

  @spec plan_delete_action(String.t(), String.t(), binary() | nil, binary() | nil) ::
          {:ok, map()}
  defp plan_delete_action(path, _real_path, _original, nil) do
    {:ok, %{kind: :result, result: {path, :ok}}}
  end

  defp plan_delete_action(path, real_path, original, current_real)
       when current_real == original do
    {:ok,
     %{
       kind: :delete,
       real_path: real_path,
       result: {path, :ok}
     }}
  end

  defp plan_delete_action(path, _real_path, nil, _current_real) do
    {:ok, %{kind: :result, result: {path, {:conflict, :both_created}}}}
  end

  defp plan_delete_action(path, _real_path, _original, _current_real) do
    {:ok, %{kind: :result, result: {path, {:conflict, :modified_before_delete}}}}
  end

  @spec apply_merge_plan([map()]) ::
          :ok | {:ok, :merged_with_conflicts, list()} | {:error, term()}
  defp apply_merge_plan(plan) do
    plan
    |> Enum.reduce_while({:ok, []}, &apply_merge_plan_reducer/2)
    |> merge_plan_result()
  end

  @spec apply_merge_plan_reducer(map(), {:ok, [tuple()]}) ::
          {:cont, {:ok, [tuple()]}} | {:halt, {:error, term()}}
  defp apply_merge_plan_reducer(entry, {:ok, results}) do
    case apply_merge_plan_entry(entry) do
      {:error, reason} -> {:halt, {:error, reason}}
      result -> {:cont, {:ok, [result | results]}}
    end
  end

  @spec merge_plan_result({:ok, [tuple()]} | {:error, term()}) ::
          :ok | {:ok, :merged_with_conflicts, list()} | {:error, term()}
  defp merge_plan_result({:error, reason}), do: {:error, reason}

  defp merge_plan_result({:ok, results}) do
    results
    |> Enum.reverse()
    |> merge_plan_success_result()
  end

  @spec merge_plan_success_result([tuple()]) :: :ok | {:ok, :merged_with_conflicts, list()}
  defp merge_plan_success_result(results) do
    if Enum.any?(results, &match?({_path, {:conflict, _}}, &1)) do
      {:ok, :merged_with_conflicts, results}
    else
      :ok
    end
  end

  @spec apply_merge_plan_entry(map()) :: tuple() | {:error, term()}
  defp apply_merge_plan_entry(%{kind: :result, result: result}), do: result

  defp apply_merge_plan_entry(
         %{
           kind: :write,
           real_path: real_path,
           content: content,
           result: result
         } = entry
       ) do
    if Map.get(entry, :mkdir_p, false) do
      File.mkdir_p!(Path.dirname(real_path))
    end

    File.write!(real_path, content)
    result
  end

  defp apply_merge_plan_entry(%{
         kind: :merge3,
         real_path: real_path,
         path: path,
         original: original,
         current_real: current_real,
         content: content
       }) do
    ancestor_lines = String.split(original, "\n", trim: false)
    ours_lines = String.split(content, "\n", trim: false)
    theirs_lines = String.split(current_real, "\n", trim: false)

    case Minga.Core.Diff.merge3(ancestor_lines, ours_lines, theirs_lines) do
      {:ok, merged_lines} ->
        File.write!(real_path, Enum.join(merged_lines, "\n"))
        {path, :ok}

      {:conflict, _hunks} ->
        {path, {:conflict, :concurrent_edit}}
    end
  end

  defp apply_merge_plan_entry(%{kind: :delete, real_path: real_path, result: result}) do
    File.rm!(real_path)
    result
  end

  @spec read_current_real(String.t()) :: {:ok, binary() | nil} | {:error, term()}
  defp read_current_real(real_path) do
    case File.read(real_path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

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
      state = capture_original(state, path)
      state = push_history(state, path)

      case Overlay.materialize_file(state.overlay, path, new_content) do
        :ok -> {:ok, put_in(state.modifications[path], new_content)}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :text_not_found}
      {:error, reason} -> {:error, reason}
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
      case Map.get(state.modifications, path) do
        nil -> :unmodified
        content -> content
      end

    history = Map.get(state.history, path, [])
    put_in(state.history[path], [current | history])
  end

  @spec restore_original(state(), String.t()) :: :ok
  defp restore_original(state, path) do
    overlay_path = Path.join(state.overlay.overlay_dir, path)

    File.rm(overlay_path)
    File.rm(overlay_path <> ".__changeset_deleted__")

    case safe_real_path(state, path) do
      {:ok, project_path} ->
        if File.regular?(project_path) do
          File.mkdir_p!(Path.dirname(overlay_path))
          relink_file(state.overlay, project_path, overlay_path)
        end

      {:error, _reason} ->
        :ok
    end

    :ok
  end

  @spec relink_file(Overlay.t(), String.t(), String.t()) :: :ok
  defp relink_file(%Overlay{link_mode: :hardlink}, source, target) do
    case File.ln(source, target) do
      :ok -> :ok
      {:error, _} -> File.cp!(source, target)
    end
  end

  defp relink_file(%Overlay{link_mode: :copy}, source, target) do
    File.cp!(source, target)
  end

  @spec normalize_path(state(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_traversal | :symlink_traversal}
  defp normalize_path(state, path) do
    case safe_real_path(state, path) do
      {:ok, target} -> {:ok, Path.relative_to(target, Path.expand(state.project_root))}
      {:error, _} = error -> error
    end
  end

  @spec safe_real_path(state(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_traversal | :symlink_traversal}
  defp safe_real_path(%{project_root: project_root}, path) do
    PathResolver.resolve(project_root, path)
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
