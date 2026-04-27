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
    modification_results =
      Enum.map(state.modifications, fn {path, changeset_content} ->
        merge_one_file(state, path, changeset_content)
      end)

    deletion_results =
      Enum.map(state.deletions, fn path ->
        merge_one_deletion(state, path)
      end)

    all_results = modification_results ++ deletion_results
    conflicts = Enum.filter(all_results, &match?({:conflict, _, _}, &1))

    if conflicts == [] do
      :ok
    else
      {:ok, :merged_with_conflicts, all_results}
    end
  end

  @spec merge_one_file(state(), String.t(), binary()) :: tuple()
  defp merge_one_file(state, path, changeset_content) do
    real_path = Path.join(state.project_root, path)
    original = Map.get(state.originals, path)

    current_real =
      case File.read(real_path) do
        {:ok, c} -> c
        {:error, :enoent} -> nil
      end

    merge_strategy(real_path, path, original, current_real, changeset_content)
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
    original = Map.get(state.originals, path)

    case File.read(real_path) do
      {:ok, content} when content == original ->
        File.rm!(real_path)
        {:ok, path, :deleted}

      {:ok, _changed} ->
        {:conflict, path, :modified_before_delete}

      {:error, :enoent} ->
        {:ok, path, :already_deleted}
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
    project_path = Path.join(state.project_root, path)

    File.rm(overlay_path)
    File.rm(overlay_path <> ".__changeset_deleted__")

    if File.regular?(project_path) do
      File.mkdir_p!(Path.dirname(overlay_path))
      relink_file(state.overlay, project_path, overlay_path)
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
