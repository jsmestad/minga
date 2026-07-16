defmodule MingaEditor.State.FileTree.Watchers do
  @moduledoc """
  File-tree-owned watcher intent and cleanup lineage.

  Candidates are retained until the latest exact synchronization succeeds.
  Failed, canceled, and stale work can therefore be recovered by the next exact
  request without relying on an effect queue's bounded history.
  """

  alias Minga.Project.FileTree

  @type request :: %{token: reference(), target: String.t() | nil}

  @type t :: %__MODULE__{
          candidates: MapSet.t(String.t()),
          target: String.t() | nil,
          expanded_dirs: MapSet.t(String.t()),
          request: request() | nil,
          retry_token: reference() | nil,
          retry_attempt: non_neg_integer(),
          generation: non_neg_integer()
        }

  defstruct candidates: MapSet.new(),
            target: nil,
            expanded_dirs: MapSet.new(),
            request: nil,
            retry_token: nil,
            retry_attempt: 0,
            generation: 0

  @doc "Records a desired tree while retaining every known cleanup root."
  @spec retarget(t(), [String.t()], FileTree.t()) :: t()
  def retarget(%__MODULE__{} = watchers, roots, %FileTree{} = tree) when is_list(roots) do
    target = Path.expand(tree.root)

    %{
      watchers
      | candidates: add_roots(watchers.candidates, [target | roots]),
        target: target,
        expanded_dirs: expand_set(tree.expanded),
        retry_token: nil,
        retry_attempt: 0,
        generation: watchers.generation + 1
    }
  end

  @doc "Records cleanup of all known roots with no replacement target."
  @spec cleanup(t(), [String.t()]) :: t()
  def cleanup(%__MODULE__{} = watchers, roots) when is_list(roots) do
    %{
      watchers
      | candidates: add_roots(watchers.candidates, roots),
        target: nil,
        expanded_dirs: MapSet.new(),
        retry_token: nil,
        retry_attempt: 0,
        generation: watchers.generation + 1
    }
  end

  @doc "Correlates the latest admitted watcher request with its exact target."
  @spec request_admitted(t(), reference()) :: t()
  def request_admitted(%__MODULE__{} = watchers, token) when is_reference(token) do
    %{watchers | request: %{token: token, target: watchers.target}, retry_token: nil}
  end

  @doc "Collapses ownership only after the latest exact request succeeds."
  @spec synchronized(t(), reference(), String.t() | nil) :: {:current | :stale, t()}
  def synchronized(
        %__MODULE__{target: target, request: %{token: token, target: target}} = watchers,
        token,
        target
      ) do
    candidates = if is_binary(target), do: MapSet.new([target]), else: MapSet.new()

    {:current,
     %{
       watchers
       | candidates: candidates,
         request: nil,
         retry_token: nil,
         retry_attempt: 0
     }}
  end

  def synchronized(%__MODULE__{} = watchers, _token, _target), do: {:stale, watchers}

  @doc "Finishes a failed or canceled exact request without dropping cleanup lineage."
  @spec request_finished(t(), reference()) :: {:current | :stale, t()}
  def request_finished(%__MODULE__{request: %{token: token}} = watchers, token) do
    {:current, %{watchers | request: nil}}
  end

  def request_finished(%__MODULE__{} = watchers, _token), do: {:stale, watchers}

  @doc "Correlates one bounded retry while retaining the current watcher intent."
  @spec retry_scheduled(t(), reference()) :: {pos_integer(), t()}
  def retry_scheduled(%__MODULE__{} = watchers, token) when is_reference(token) do
    attempt = watchers.retry_attempt + 1
    {attempt, %{watchers | retry_token: token, retry_attempt: attempt}}
  end

  @doc "Consumes only the current watcher retry timer."
  @spec retry_elapsed(t(), reference()) :: {:current | :stale, t()}
  def retry_elapsed(%__MODULE__{retry_token: token} = watchers, token) do
    {:current, %{watchers | retry_token: nil}}
  end

  def retry_elapsed(%__MODULE__{} = watchers, _token), do: {:stale, watchers}

  @doc "Terminalizes retry correlation while preserving the failed attempt count."
  @spec retry_exhausted(t()) :: t()
  def retry_exhausted(%__MODULE__{} = watchers), do: %{watchers | retry_token: nil}

  @spec add_roots(MapSet.t(String.t()), [String.t()]) :: MapSet.t(String.t())
  defp add_roots(candidates, roots) do
    Enum.reduce(roots, candidates, fn root, acc ->
      if is_binary(root), do: MapSet.put(acc, Path.expand(root)), else: acc
    end)
  end

  @spec expand_set(MapSet.t(String.t())) :: MapSet.t(String.t())
  defp expand_set(%MapSet{} = paths), do: MapSet.new(paths, &Path.expand/1)
end
