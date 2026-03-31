defmodule Changeset.Server do
  @moduledoc """
  GenServer managing a single changeset's lifecycle.

  Holds modified file contents in memory and keeps the overlay directory
  in sync. Maintains an edit history per file for undo support.
  """

  use GenServer, restart: :temporary

  alias Changeset.Overlay
  alias Changeset.Merge

  @type state :: %{
          project_root: String.t(),
          overlay: Overlay.t(),
          modifications: %{String.t() => binary()},
          originals: %{String.t() => binary()},
          deletions: MapSet.t(String.t()),
          history: %{String.t() => [binary()]},
          budget: pos_integer() | :unlimited,
          attempts: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
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

  @impl true
  def handle_call({:write_file, relative_path, content}, _from, state) do
    path = normalize_path(relative_path)
    state = capture_original(state, path)
    state = push_history(state, path)

    case Overlay.materialize_file(state.overlay, path, content) do
      :ok ->
        state = put_in(state.modifications[path], content)
        state = %{state | deletions: MapSet.delete(state.deletions, path)}
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:edit_file, relative_path, old_text, new_text}, _from, state) do
    path = normalize_path(relative_path)

    case current_content(state, path) do
      {:ok, content} ->
        if String.contains?(content, old_text) do
          new_content = String.replace(content, old_text, new_text, global: false)
          state = capture_original(state, path)
          state = push_history(state, path)

          case Overlay.materialize_file(state.overlay, path, new_content) do
            :ok ->
              state = put_in(state.modifications[path], new_content)
              {:reply, :ok, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        else
          {:reply, {:error, :text_not_found}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete_file, relative_path}, _from, state) do
    path = normalize_path(relative_path)
    state = capture_original(state, path)
    state = push_history(state, path)

    case Overlay.delete_file(state.overlay, path) do
      :ok ->
        state = %{state | deletions: MapSet.put(state.deletions, path)}
        state = %{state | modifications: Map.delete(state.modifications, path)}
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:undo, relative_path}, _from, state) do
    path = normalize_path(relative_path)

    case Map.get(state.history, path) do
      [prev | rest] ->
        # Restore previous content (or remove if undoing back to unmodified)
        state = put_in(state.history[path], rest)

        if prev == :unmodified do
          # Restore the original hardlink/copy
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

  def handle_call({:read_file, relative_path}, _from, state) do
    path = normalize_path(relative_path)
    {:reply, current_content(state, path), state}
  end

  def handle_call(:overlay_path, _from, state) do
    {:reply, state.overlay.overlay_dir, state}
  end

  def handle_call(:command_env, _from, state) do
    {:reply, Overlay.command_env(state.overlay), state}
  end

  def handle_call(:modified_files, _from, state) do
    modified = Map.keys(state.modifications) |> Enum.sort()
    deleted = MapSet.to_list(state.deletions) |> Enum.sort()
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
    # Undo everything: restore all files to original state
    Enum.each(state.modifications, fn {path, _} ->
      restore_original(state, path)
    end)

    Enum.each(state.deletions, fn path ->
      restore_original(state, path)
    end)

    state = %{state |
      modifications: %{},
      deletions: MapSet.new(),
      history: %{}
    }

    {:reply, :ok, state}
  end

  def handle_call(:merge, _from, state) do
    result = do_merge(state)

    case result do
      :ok ->
        Overlay.cleanup(state.overlay)
        {:stop, :normal, :ok, state}

      {:ok, :merged_with_conflicts, details} ->
        Overlay.cleanup(state.overlay)
        {:stop, :normal, {:ok, :merged_with_conflicts, details}, state}

      {:error, _reason} = error ->
        # Don't stop on merge error; let the caller decide
        {:reply, error, state}
    end
  end

  def handle_call(:discard, _from, state) do
    Overlay.cleanup(state.overlay)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def terminate(_reason, %{overlay: overlay}) when not is_nil(overlay) do
    Overlay.cleanup(overlay)
  end

  def terminate(_reason, _state), do: :ok

  # -- Merge logic --

  defp do_merge(state) do
    results =
      Enum.map(state.modifications, fn {path, changeset_content} ->
        real_path = Path.join(state.project_root, path)
        original = Map.get(state.originals, path)

        # Read current real content (may have changed since changeset was created)
        current_real = case File.read(real_path) do
          {:ok, c} -> c
          {:error, :enoent} -> nil
        end

        cond do
          # New file (didn't exist when changeset was created)
          is_nil(original) ->
            if is_nil(current_real) do
              # Still doesn't exist on disk. Safe to create.
              File.mkdir_p!(Path.dirname(real_path))
              File.write!(real_path, changeset_content)
              {:ok, path, :created}
            else
              # Someone else created it while we were working
              {:conflict, path, :both_created}
            end

          # Real file unchanged since changeset was created
          current_real == original ->
            File.write!(real_path, changeset_content)
            {:ok, path, :applied}

          # Real file was also modified (concurrent edit)
          true ->
            case Merge.three_way(original, changeset_content, current_real) do
              {:ok, merged} ->
                File.write!(real_path, merged)
                {:ok, path, :merged_three_way}

              {:conflict, hunks} ->
                {:conflict, path, hunks}
            end
        end
      end)

    # Handle deletions
    deletion_results =
      Enum.map(state.deletions, fn path ->
        real_path = Path.join(state.project_root, path)
        original = Map.get(state.originals, path)
        current_real = File.read(real_path)

        case current_real do
          {:ok, content} when content == original ->
            File.rm!(real_path)
            {:ok, path, :deleted}

          {:ok, _changed} ->
            {:conflict, path, :modified_before_delete}

          {:error, :enoent} ->
            {:ok, path, :already_deleted}
        end
      end)

    all_results = results ++ deletion_results
    conflicts = Enum.filter(all_results, &match?({:conflict, _, _}, &1))

    if conflicts == [] do
      :ok
    else
      {:ok, :merged_with_conflicts, all_results}
    end
  end

  # -- Private helpers --

  defp current_content(state, path) do
    cond do
      MapSet.member?(state.deletions, path) ->
        {:error, :deleted}

      Map.has_key?(state.modifications, path) ->
        {:ok, Map.fetch!(state.modifications, path)}

      true ->
        File.read(Path.join(state.project_root, path))
    end
  end

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

  # Push current state onto the undo stack for this file
  defp push_history(state, path) do
    current =
      case Map.get(state.modifications, path) do
        nil -> :unmodified
        content -> content
      end

    history = Map.get(state.history, path, [])
    put_in(state.history[path], [current | history])
  end

  defp restore_original(state, path) do
    overlay_path = Path.join(state.overlay.overlay_dir, path)
    project_path = Path.join(state.project_root, path)

    # Remove modified file and any deletion marker
    File.rm(overlay_path)
    File.rm(overlay_path <> ".__changeset_deleted__")

    # Re-link from project if file exists
    if File.regular?(project_path) do
      File.mkdir_p!(Path.dirname(overlay_path))

      case state.overlay.link_mode do
        :hardlink ->
          case File.ln(project_path, overlay_path) do
            :ok -> :ok
            {:error, _} -> File.cp!(project_path, overlay_path)
          end

        :copy ->
          File.cp!(project_path, overlay_path)
      end
    end
  end

  defp normalize_path(path) do
    path
    |> String.trim_leading("/")
    |> String.trim_leading("./")
  end
end
