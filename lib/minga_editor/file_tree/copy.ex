defmodule MingaEditor.FileTree.Copy do
  @moduledoc """
  Runs file-tree copies and ordered drops on the lane shared with confirmed deletion.

  The Editor captures paths and the presenting tree generation, not selections or
  clipboard state. The worker chooses duplicate suffixes and exclusively claims
  each destination before copying, so only a claimed output is eligible for cleanup.
  """

  @behaviour MingaEditor.Effect

  alias Minga.Log
  alias Minga.Project.FileTree
  alias Minga.Project.Root
  alias MingaEditor.Commands.FileTree, as: FileTreeCommands
  alias MingaEditor.Commands.FileTree.DuplicateBackend
  alias MingaEditor.Commands.FileTree.SystemDuplicateBackend
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.FileTree.Freshness
  alias MingaEditor.FileTree.Mutation
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState

  @type drop_item ::
          {:copy | :move, source :: String.t(), destination :: String.t()}
          | {:stale_source, source :: String.t()}
  @typep operation ::
           {:duplicate, source :: String.t()}
           | {:paste, source :: String.t(), destination :: String.t()}
           | {:drop, [drop_item()]}
  @typep kind :: :duplicate | :paste | :drop
  @typep source_kind :: DuplicateBackend.entry_type() | {:directory_link, String.t()}
  @typep cleanup :: :removed | {:failed, term(), String.t()}
  @typep result ::
           {:copied, source :: String.t(), destination :: String.t()}
           | {:moved, source :: String.t(), destination :: String.t()}
           | {:move_failed, source :: String.t(), destination :: String.t(), reason :: term()}
           | {:stale_source, source :: String.t()}
           | {:unchanged, path :: String.t()}
           | {:claim_failed, destination :: String.t(), reason :: term()}
           | {:rejected, source :: String.t(), destination :: String.t(), reason :: term()}
           | {:copy_failed, destination :: String.t(), failed_path :: String.t(),
              reason :: term(), cleanup()}

  @enforce_keys [:operation, :root, :generation, :backend]
  defstruct [:operation, :root, :generation, :backend]

  @type t :: %__MODULE__{
          operation: operation(),
          root: String.t(),
          generation: non_neg_integer(),
          backend: DuplicateBackend.t()
        }

  @doc "Schedules a copy using the next available sibling name."
  @spec duplicate(EditorState.t(), String.t()) :: EditorState.t()
  def duplicate(state, source) do
    submit(state, {:duplicate, source}, state.interaction.file_tree_duplicate_backend)
  end

  @doc "Schedules a copy of the marked path without changing the clipboard mark."
  @spec paste(EditorState.t(), String.t(), String.t()) :: EditorState.t()
  def paste(state, source, destination) do
    submit(state, {:paste, source, destination}, {SystemDuplicateBackend, nil})
  end

  @doc "Schedules the entire admitted drop in source order, including internal moves."
  @spec drop(EditorState.t(), [drop_item()]) :: EditorState.t()
  def drop(state, []), do: state

  def drop(state, items) do
    submit(state, {:drop, items}, {SystemDuplicateBackend, nil})
  end

  @spec submit(EditorState.t(), operation(), DuplicateBackend.t()) :: EditorState.t()
  defp submit(state, operation, backend) do
    case FileTreeState.tree(state.workspace.file_tree) do
      %FileTree{root: root} ->
        effect = %__MODULE__{
          operation: operation,
          root: root,
          generation: FileTreeState.presentation_generation(state.workspace.file_tree),
          backend: backend
        }

        case Mutation.schedule(state, effect) do
          {:ok, _id, :running} -> state
          {:error, reason} -> report_admission_failure(state, operation, reason)
        end

      nil ->
        state
    end
  end

  @spec report_admission_failure(EditorState.t(), operation(), term()) :: EditorState.t()
  defp report_admission_failure(state, operation, reason) do
    message =
      case reason do
        :queue_full -> "Another file tree mutation is already running"
        _other -> "#{action_name(elem(operation, 0))} could not start: #{inspect(reason)}"
      end

    Log.warning(:editor, "[file-tree] #{message}")
    NoticeWorkflow.publish(state, message)
  end

  @impl true
  @spec run(t()) :: {:ok, [result()]} | {:error, {:mutations, [result()]}}
  def run(%__MODULE__{operation: operation, backend: backend}) do
    results = perform(operation, backend)

    if Enum.all?(results, &successful?/1),
      do: {:ok, results},
      else: {:error, {:mutations, results}}
  end

  @spec successful?(result()) :: boolean()
  defp successful?({status, _, _}) when status in [:copied, :moved], do: true
  defp successful?({:unchanged, _path}), do: true
  defp successful?(_result), do: false

  @spec perform(operation(), DuplicateBackend.t()) :: [result()]
  defp perform({:duplicate, source}, backend) do
    base = Path.rootname(source)
    ext = Path.extname(source)
    destination = available_copy_path("#{base} copy#{ext}", base, ext, 2)
    [copy(source, destination, backend)]
  end

  defp perform({:paste, source, destination}, backend), do: [copy(source, destination, backend)]

  defp perform({:drop, items}, backend) do
    Enum.map(items, fn
      {:copy, source, destination} -> copy(source, destination, backend)
      {:move, source, destination} -> move(source, destination)
      {:stale_source, _source} = rejected -> rejected
    end)
  end

  @spec move(String.t(), String.t()) :: result()
  defp move(source, destination) do
    if same_path?(source, destination) do
      {:unchanged, source}
    else
      case rename_without_collision(source, destination) do
        :ok -> {:moved, source, destination}
        {:error, reason} -> {:move_failed, source, destination, reason}
      end
    end
  end

  @spec rename_without_collision(String.t(), String.t()) :: :ok | {:error, term()}
  defp rename_without_collision(source, destination) do
    case File.lstat(destination) do
      {:error, :enoent} -> File.rename(source, destination)
      _existing_or_unverified -> {:error, {:destination_exists, destination}}
    end
  end

  @spec same_path?(String.t(), String.t()) :: boolean()
  defp same_path?(left, right), do: resolved_path(left) == resolved_path(right)

  @spec resolved_path(String.t()) :: String.t()
  defp resolved_path(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, target} -> List.to_string(target)
      {:error, _reason} -> Path.expand(path)
    end
  end

  @spec available_copy_path(String.t(), String.t(), String.t(), pos_integer()) :: String.t()
  defp available_copy_path(candidate, base, ext, next) do
    case File.lstat(candidate) do
      {:ok, _stat} -> available_copy_path("#{base} copy #{next}#{ext}", base, ext, next + 1)
      {:error, _reason} -> candidate
    end
  end

  @spec copy(String.t(), String.t(), DuplicateBackend.t()) :: result()
  defp copy(source, destination, backend) do
    # Resolve parent aliases before claiming the final entry. Never resolve the
    # destination itself: a dangling link occupying that name is a collision.
    with {:ok, parent} <- Root.canonical_path(Path.dirname(destination)),
         {:ok, kind} <- source_kind(source, parent) do
      target = Path.join(parent, Path.basename(destination))
      claim_and_copy(source, target, destination, kind, backend)
    else
      {:error, reason} -> {:rejected, source, destination, reason}
    end
  end

  @spec source_kind(String.t(), String.t()) :: {:ok, source_kind()} | {:error, term()}
  defp source_kind(source, parent) do
    case File.lstat(source) do
      {:ok, %File.Stat{type: :symlink}} -> linked_source_kind(source, parent)
      {:ok, %File.Stat{type: :directory} = stat} -> directory_kind(parent, stat, :directory)
      {:ok, %File.Stat{type: :regular}} -> {:ok, :file}
      {:ok, %File.Stat{type: type}} -> {:error, {:unsupported_source_type, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Like File.cp and File.cp_r, read a top-level file link's bytes but preserve
  # directory links as links. Recursive copies also preserve links below the root.
  @spec linked_source_kind(String.t(), String.t()) :: {:ok, source_kind()} | {:error, term()}
  defp linked_source_kind(source, parent) do
    case File.stat(source) do
      {:ok, %File.Stat{type: :regular}} ->
        {:ok, :file}

      {:ok, %File.Stat{type: :directory} = stat} ->
        with {:ok, target} <- File.read_link(source) do
          directory_kind(parent, stat, {:directory_link, target})
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unsupported_source_type, type}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec directory_kind(String.t(), File.Stat.t(), source_kind()) ::
          {:ok, source_kind()} | {:error, term()}
  defp directory_kind(parent, source_stat, kind) do
    case File.stat(parent) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        # Identity catches case-insensitive aliases as well as symlink aliases
        # resolved above, including when the destination is below such an alias.
        if same_directory?(stat, source_stat) do
          {:error, :destination_inside_source}
        else
          parent_kind(parent, source_stat, kind)
        end

      {:ok, _stat} ->
        {:error, :enotdir}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec parent_kind(String.t(), File.Stat.t(), source_kind()) ::
          {:ok, source_kind()} | {:error, term()}
  defp parent_kind(path, source_stat, kind) do
    case Path.dirname(path) do
      ^path -> {:ok, kind}
      parent -> directory_kind(parent, source_stat, kind)
    end
  end

  @spec same_directory?(File.Stat.t(), File.Stat.t()) :: boolean()
  defp same_directory?(first, second) do
    first.inode == second.inode and first.major_device == second.major_device and
      first.minor_device == second.minor_device
  end

  @spec claim_and_copy(String.t(), String.t(), String.t(), source_kind(), DuplicateBackend.t()) ::
          result()
  defp claim_and_copy(source, target, destination, {:directory_link, link}, _backend) do
    # Creating the link is both an exclusive claim and the whole copy.
    case File.ln_s(link, target) do
      :ok -> {:copied, source, destination}
      {:error, reason} -> {:claim_failed, destination, reason}
    end
  end

  defp claim_and_copy(source, target, destination, kind, {backend, context}) do
    case backend.claim_destination(target, kind, context) do
      {:ok, claim} -> copy_claimed(source, destination, claim, backend, context)
      {:error, reason} -> {:claim_failed, destination, reason}
    end
  end

  @spec copy_claimed(String.t(), String.t(), DuplicateBackend.claim(), module(), term()) ::
          result()
  defp copy_claimed(source, destination, claim, backend, context) do
    case backend.copy(source, claim, context) do
      :ok ->
        {:copied, source, destination}

      {:error, reason, path, owned} ->
        copy_failed(destination, path, reason, owned, backend, context)
    end
  end

  @spec copy_failed(
          String.t(),
          String.t(),
          term(),
          [DuplicateBackend.owned_entry()],
          module(),
          term()
        ) :: result()
  defp copy_failed(destination, failed_path, reason, owned, backend, context) do
    cleanup =
      case backend.cleanup(owned, context) do
        :ok -> :removed
        {:error, cleanup_reason, path} -> {:failed, cleanup_reason, path}
      end

    {:copy_failed, destination, failed_path, reason, cleanup}
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(state, %Outcome{request: %{effect: effect}, value: {status, value}} = outcome)
      when status in [:completed, :failed] do
    current? = current_tree?(state.workspace.file_tree, effect)
    kind = elem(effect.operation, 0)
    state = report_completion(state, kind, current?, status, value)

    if current? do
      {Freshness.request_refresh(state, 0), outcome}
    else
      {state, Outcome.stale(outcome, :file_tree_changed)}
    end
  end

  def apply(state, %Outcome{request: %{effect: effect}, value: {:canceled, reason}} = outcome) do
    message = "#{action_name(elem(effect.operation, 0))} canceled: #{inspect(reason)}"
    Log.warning(:editor, "[file-tree] #{message}")
    {state, outcome}
  end

  def apply(state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{request: %{effect: %{operation: {:duplicate, _}}}, value: {status, _}}),
    do: status in [:completed, :failed]

  def render?(%Outcome{}), do: false

  @spec current_tree?(FileTreeState.t(), t()) :: boolean()
  defp current_tree?(file_tree, %__MODULE__{root: root, generation: generation}) do
    FileTreeState.presentation_generation(file_tree) == generation and
      match?(%FileTree{root: ^root}, FileTreeState.tree(file_tree))
  end

  @spec report_completion(EditorState.t(), kind(), boolean(), :completed | :failed, term()) ::
          EditorState.t()
  defp report_completion(state, kind, current?, :completed, results),
    do: report_results(state, kind, current?, results)

  defp report_completion(state, kind, current?, :failed, {:mutations, results}),
    do: report_results(state, kind, current?, results)

  defp report_completion(state, kind, current?, :failed, reason) do
    message = "#{action_name(kind)} worker failed: #{inspect(reason)}"
    report(state, kind, current?, :error, message)
  end

  @spec report_results(EditorState.t(), kind(), boolean(), [result()]) :: EditorState.t()
  defp report_results(state, kind, current?, results) do
    Enum.reduce(results, state, fn
      {:unchanged, path}, state ->
        Log.info(:editor, "[file-tree] Drop unchanged: #{path}")
        state

      {:moved, source, destination}, state ->
        message = "Moved: #{Path.basename(source)} → #{Path.dirname(destination)}"
        Log.info(:editor, "[file-tree] #{message}")
        FileTreeCommands.sync_moved_buffer_path(state, source, destination, "Move")

      result, state ->
        {status, message} = result_message(kind, result)
        report(state, kind, current?, status, message)
    end)
  end

  @spec report(EditorState.t(), kind(), boolean(), :ok | :error, String.t()) :: EditorState.t()
  defp report(state, kind, current?, status, message) do
    case status do
      :ok -> Log.info(:editor, "[file-tree] #{message}")
      :error -> Log.warning(:editor, "[file-tree] #{message}")
    end

    if current? and kind == :duplicate, do: NoticeWorkflow.publish(state, message), else: state
  end

  @spec result_message(kind(), result()) :: {:ok | :error, String.t()}
  defp result_message(:duplicate, {:copied, source, destination}) do
    {:ok, "Duplicated #{Path.basename(source)} to #{Path.basename(destination)}"}
  end

  defp result_message(_kind, {:copied, source, destination}) do
    {:ok, "Copied: #{Path.basename(source)} → #{Path.dirname(destination)}"}
  end

  defp result_message(:drop, {:stale_source, source}) do
    {:error, "Drop rejected: stale source #{source}"}
  end

  defp result_message(:drop, {:move_failed, source, destination, reason}) do
    {:error, "Move failed: #{source} → #{destination}: #{inspect(reason)}"}
  end

  defp result_message(:drop, {:claim_failed, destination, :eexist}) do
    {:error, "Drop copy skipped, destination exists: #{destination}"}
  end

  defp result_message(kind, {:claim_failed, destination, :eexist}) do
    {:error, "#{action_name(kind)} destination already exists: #{destination}"}
  end

  defp result_message(kind, {:claim_failed, destination, reason}) do
    {:error,
     "#{copy_action_name(kind)} failed to create destination #{destination}: #{format_error(reason)}"}
  end

  defp result_message(kind, {:rejected, source, destination, reason}) do
    {:error,
     "#{copy_action_name(kind)} failed: #{source} → #{destination}: #{format_error(reason)}"}
  end

  defp result_message(kind, {:copy_failed, destination, path, reason, cleanup}) do
    {:error,
     "#{copy_action_name(kind)} failed while copying #{path} to #{destination}: #{format_error(reason)}. #{cleanup_message(cleanup, destination)}"}
  end

  @spec cleanup_message(cleanup(), String.t()) :: String.t()
  defp cleanup_message(:removed, _destination), do: "Partial output was removed"

  defp cleanup_message({:failed, reason, path}, destination) do
    "Cleanup failed at #{path}: #{format_error(reason)}; partial destination remains at #{destination}"
  end

  @spec action_name(kind()) :: String.t()
  defp action_name(:duplicate), do: "Duplicate"
  defp action_name(:paste), do: "Copy"
  defp action_name(:drop), do: "Drop"

  @spec copy_action_name(kind()) :: String.t()
  defp copy_action_name(:drop), do: "Drop copy"
  defp copy_action_name(kind), do: action_name(kind)

  @spec format_error(term()) :: String.t()
  defp format_error(:destination_inside_source), do: "destination is inside the source directory"

  defp format_error(reason) when is_atom(reason) do
    case reason |> :file.format_error() |> to_string() do
      "unknown POSIX error" -> inspect(reason)
      message -> message
    end
  end

  defp format_error(reason), do: inspect(reason)
end
