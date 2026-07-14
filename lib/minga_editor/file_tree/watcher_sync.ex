defmodule MingaEditor.FileTree.WatcherSync do
  @moduledoc """
  Typed, serialized synchronization of file-tree watcher ownership.

  Every request carries the full cleanup lineage plus the newest desired target.
  Coalescing unions cleanup roots while retaining that newest target, so queued
  reroot bursts cannot leak intermediate watchers.
  """

  @behaviour MingaEditor.Effect

  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.FileTree.Freshness
  alias MingaEditor.FileTree.WatcherSync.FileWatcherBackend
  alias MingaEditor.FileTree.WatcherSync.Result
  alias MingaEditor.State, as: EditorState

  @resource :file_tree_watcher_sync

  @enforce_keys [:candidates, :target, :expanded_dirs, :backend, :backend_context]
  defstruct [:candidates, :target, :expanded_dirs, :backend, :backend_context]

  @type t :: %__MODULE__{
          candidates: MapSet.t(String.t()),
          target: String.t() | nil,
          expanded_dirs: MapSet.t(String.t()),
          backend: module(),
          backend_context: term()
        }

  @doc "Builds one coalescing request on the stable watcher resource."
  @spec request(MapSet.t(String.t()), String.t() | nil, MapSet.t(String.t()), keyword()) ::
          Request.t()
  def request(candidates, target, expanded_dirs, opts \\ []) do
    effect = %__MODULE__{
      candidates: expand_set(candidates),
      target: expand_optional(target),
      expanded_dirs: expand_set(expanded_dirs),
      backend: Keyword.get(opts, :watcher_backend, FileWatcherBackend),
      backend_context: Keyword.get(opts, :watcher_context)
    }

    Request.new(effect, @resource, Policy.coalescing(1))
  end

  @impl true
  @spec run(t()) :: {:ok, Result.t()} | {:error, term()}
  def run(%__MODULE__{} = effect) do
    with :ok <- unwatch_obsolete_roots(effect),
         :ok <- watch_target_dirs(effect) do
      {:ok, Result.new(effect.target)}
    end
  end

  @impl true
  @spec coalesce(t(), t()) :: t()
  def coalesce(%__MODULE__{} = older, %__MODULE__{} = newer) do
    %{newer | candidates: MapSet.union(older.candidates, newer.candidates)}
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(%EditorState{} = state, %Outcome{} = outcome) do
    Freshness.apply_watcher_outcome(state, outcome)
  end

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{}), do: false

  @spec unwatch_obsolete_roots(t()) :: :ok | {:error, term()}
  defp unwatch_obsolete_roots(%__MODULE__{} = effect) do
    effect.candidates
    |> Enum.reject(&same_target?(&1, effect.target))
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn root, :ok ->
      case effect.backend.unwatch_directory_tree(root, effect.backend_context) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
        other -> {:halt, {:error, {:invalid_unwatch_result, root, other}}}
      end
    end)
  end

  @spec watch_target_dirs(t()) :: :ok | {:error, term()}
  defp watch_target_dirs(%__MODULE__{target: nil}), do: :ok

  defp watch_target_dirs(%__MODULE__{} = effect) do
    effect.expanded_dirs
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case effect.backend.watch_directory(path, effect.backend_context) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
        other -> {:halt, {:error, {:invalid_watch_result, path, other}}}
      end
    end)
  end

  @spec same_target?(String.t(), String.t() | nil) :: boolean()
  defp same_target?(_root, nil), do: false
  defp same_target?(root, target), do: Path.expand(root) == Path.expand(target)

  @spec expand_optional(String.t() | nil) :: String.t() | nil
  defp expand_optional(nil), do: nil
  defp expand_optional(path) when is_binary(path), do: Path.expand(path)

  @spec expand_set(MapSet.t(String.t())) :: MapSet.t(String.t())
  defp expand_set(%MapSet{} = paths), do: MapSet.new(paths, &Path.expand/1)
end
