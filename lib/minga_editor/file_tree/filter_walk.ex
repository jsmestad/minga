defmodule MingaEditor.FileTree.FilterWalk do
  @moduledoc """
  Typed, latest-wins filter scan for one file-tree root.

  Cache reads and fallback filesystem walks execute in the bounded effect
  scheduler. The request carries the exact root and filter identity; application
  remains in the file-tree workflow so rerooted, repeated, closed, canceled, and
  failed work cannot overwrite newer state.
  """

  @behaviour MingaEditor.Effect

  alias Minga.Project.FileTree
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.FileTree.FilterWalk.CacheOrFilesystemScanner
  alias MingaEditor.FileTree.FilterWalk.Result
  alias MingaEditor.FileTree.Freshness
  alias MingaEditor.State, as: EditorState

  @enforce_keys [:root, :filter, :tree, :scanner, :scanner_context]
  defstruct [
    :root,
    :filter,
    :tree,
    :scanner,
    :scanner_context,
    :watcher_backend,
    :watcher_context,
    synchronize_watchers?: true
  ]

  @type t :: %__MODULE__{
          root: String.t(),
          filter: String.t(),
          tree: FileTree.t(),
          scanner: module(),
          scanner_context: term(),
          watcher_backend: module() | nil,
          watcher_context: term(),
          synchronize_watchers?: boolean()
        }

  @doc "Builds a latest-wins request for the tree's exact root and active filter."
  @spec request(FileTree.t(), keyword()) :: Request.t()
  def request(%FileTree{root: root, filter: filter} = tree, opts \\ [])
      when is_binary(root) and is_binary(filter) and filter != "" do
    expanded_root = Path.expand(root)

    effect = %__MODULE__{
      root: expanded_root,
      filter: filter,
      tree: tree,
      scanner: Keyword.get(opts, :scanner, CacheOrFilesystemScanner),
      scanner_context: Keyword.get(opts, :scanner_context),
      watcher_backend: Keyword.get(opts, :watcher_backend),
      watcher_context: Keyword.get(opts, :watcher_context),
      synchronize_watchers?: Keyword.get(opts, :synchronize_watchers?, true)
    }

    Request.new(effect, {:file_tree_filter, expanded_root}, Policy.latest_wins())
  end

  @impl true
  @spec run(t()) :: {:ok, Result.t()} | {:error, term()}
  def run(%__MODULE__{} = effect) do
    case effect.scanner.scan(effect.tree, effect.scanner_context) do
      %Result{} = result -> {:ok, result}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_filter_result, other}}
    end
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(%EditorState{} = state, %Outcome{} = outcome) do
    Freshness.apply_filter_outcome(state, outcome)
  end

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{}), do: false
end
