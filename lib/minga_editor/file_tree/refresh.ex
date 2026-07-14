defmodule MingaEditor.FileTree.Refresh do
  @moduledoc """
  Typed, bounded filesystem rescan for one file-tree root.

  The expanded root is the scheduler resource identity. One scan may run while
  at most one follow-up waits; newer bursts coalesce into that queued request.
  Execution, coalescing, and application remain owned by this domain effect.
  """

  @behaviour MingaEditor.Effect

  alias Minga.Git.Repo, as: GitRepo
  alias Minga.Git.Repo.StatusSnapshot
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.GitStatus
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.FileTree.Freshness
  alias MingaEditor.State, as: EditorState

  @enforce_keys [:root, :tree, :events_registry, :scanner, :scanner_context]
  defstruct [
    :root,
    :tree,
    :events_registry,
    :scanner,
    :scanner_context,
    :previous_root,
    :watcher_backend,
    :watcher_context,
    synchronize_watchers?: true
  ]

  @typedoc "Scanner module input kept as data in the scheduler request."
  @type scanner_context :: term()

  @type t :: %__MODULE__{
          root: String.t(),
          tree: FileTree.t(),
          events_registry: Minga.Events.registry(),
          scanner: module(),
          scanner_context: scanner_context(),
          previous_root: String.t() | nil,
          watcher_backend: module() | nil,
          watcher_context: term(),
          synchronize_watchers?: boolean()
        }

  @doc "Builds a coalescing request keyed by the expanded file-tree root."
  @spec request(FileTree.t(), Minga.Events.registry(), keyword()) :: Request.t()
  def request(%FileTree{root: root} = tree, events_registry, opts \\ []) when is_binary(root) do
    expanded_root = Path.expand(root)

    effect = %__MODULE__{
      root: expanded_root,
      tree: tree,
      events_registry: events_registry,
      scanner: Keyword.get(opts, :scanner, MingaEditor.FileTree.Refresh.FilesystemScanner),
      scanner_context: Keyword.get(opts, :scanner_context),
      previous_root: expanded_optional_root(Keyword.get(opts, :previous_root)),
      watcher_backend: Keyword.get(opts, :watcher_backend),
      watcher_context: Keyword.get(opts, :watcher_context),
      synchronize_watchers?: Keyword.get(opts, :synchronize_watchers?, true)
    }

    Request.new(effect, {:file_tree_root, expanded_root}, Policy.coalescing(1))
  end

  @impl true
  @spec run(t()) :: {:ok, FileTree.t()} | {:error, term()}
  def run(%__MODULE__{} = effect) do
    case effect.scanner.scan(effect.tree, effect.scanner_context) do
      %FileTree{} = refreshed_tree ->
        {:ok, with_cached_git_status(refreshed_tree, effect.events_registry)}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_refresh_result, other}}
    end
  end

  @impl true
  @spec coalesce(t(), t()) :: t()
  def coalesce(%__MODULE__{previous_root: previous_root}, %__MODULE__{} = newer) do
    %{newer | previous_root: newer.previous_root || previous_root}
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(%EditorState{} = state, %Outcome{} = outcome) do
    Freshness.apply_refresh_outcome(state, outcome)
  end

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{}), do: false

  @doc "Adds cached git badges without performing a synchronous git status query."
  @spec with_cached_git_status(FileTree.t(), Minga.Events.registry()) :: FileTree.t()
  def with_cached_git_status(%FileTree{} = tree, events_registry) do
    case GitRepo.cached_status_for_path(tree.root) do
      {:ok, %StatusSnapshot{entry_base_path: entry_base_path, entries: entries}} ->
        status = GitStatus.from_entries(entries, entry_base_path, tree.root)
        FileTree.replace_git_status(tree, status)

      :not_tracked ->
        ensure_repo_started(tree.root, events_registry)
        tree
    end
  catch
    :exit, _reason -> tree
  end

  @spec ensure_repo_started(String.t(), Minga.Events.registry()) :: :ok
  defp ensure_repo_started(root, events_registry) when is_binary(root) do
    case Minga.Git.root_for(root) do
      {:ok, git_root} -> start_repo(git_root, root, events_registry)
      :not_git -> :ok
    end
  catch
    :exit, reason ->
      Minga.Log.warning(
        :editor,
        "File tree git repo lookup failed for #{root}: #{inspect(reason)}"
      )

      :ok
  end

  @spec expanded_optional_root(String.t() | nil) :: String.t() | nil
  defp expanded_optional_root(nil), do: nil
  defp expanded_optional_root(root) when is_binary(root), do: Path.expand(root)

  @spec start_repo(String.t(), String.t(), Minga.Events.registry()) :: :ok
  defp start_repo(git_root, root, events_registry) do
    case GitRepo.ensure_started(git_root, root, events_registry) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Minga.Log.warning(
          :editor,
          "File tree git repo start failed for #{root}: #{inspect(reason)}"
        )
    end
  end
end
