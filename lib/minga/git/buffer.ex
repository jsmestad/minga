defmodule Minga.Git.Buffer do
  @moduledoc """
  Per-buffer GenServer that tracks git diff state.

  Caches the HEAD version of the file on startup, then recomputes an
  in-memory diff (via `Minga.Core.Diff`) whenever the buffer content
  changes. This design means buffer edits never spawn git processes;
  only buffer open and git index invalidation do.

  One `Git.Buffer` exists per file-backed buffer in a git repository.
  Managed under `Minga.Buffer.Supervisor`.
  """

  use GenServer

  alias Minga.Core.Diff
  alias Minga.Git

  @typedoc "Internal state."
  @type state :: %{
          git_root: String.t(),
          relative_path: String.t(),
          base_lines: [String.t()],
          hunks: [Diff.hunk()],
          signs: %{non_neg_integer() => Diff.hunk_type()},
          branch: String.t() | nil
        }

  # ── Client API ─────────────────────────────────────────────────────────────

  @typedoc "Options for starting a git buffer."
  @type start_opt ::
          {:git_root, String.t()}
          | {:file_path, String.t()}
          | {:initial_content, String.t()}

  @doc "Starts a git buffer for a file in a git repository."
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Recomputes the diff against the cached base content."
  @spec update(GenServer.server(), String.t()) :: :ok
  def update(server, current_content) when is_binary(current_content) do
    GenServer.cast(server, {:update, current_content})
  end

  @doc "Re-reads the HEAD version and recomputes the diff."
  @spec invalidate_base(GenServer.server(), String.t()) :: :ok
  def invalidate_base(server, current_content) when is_binary(current_content) do
    GenServer.cast(server, {:invalidate_base, current_content})
  end

  @doc "Returns the per-line sign map for the gutter."
  @spec signs(GenServer.server()) :: %{non_neg_integer() => Diff.hunk_type()}
  def signs(server) do
    GenServer.call(server, :signs)
  end

  @doc "Returns the list of hunks."
  @spec hunks(GenServer.server()) :: [Diff.hunk()]
  def hunks(server) do
    GenServer.call(server, :hunks)
  end

  @doc "Returns the hunk at a specific buffer line, or nil."
  @spec hunk_at(GenServer.server(), non_neg_integer()) :: Diff.hunk() | nil
  def hunk_at(server, line) when is_integer(line) do
    GenServer.call(server, {:hunk_at, line})
  end

  @doc "Returns the git root path."
  @spec git_root(GenServer.server()) :: String.t()
  def git_root(server) do
    GenServer.call(server, :git_root)
  end

  @doc "Returns the file path relative to git root."
  @spec relative_path(GenServer.server()) :: String.t()
  def relative_path(server) do
    GenServer.call(server, :relative_path)
  end

  @typedoc "Diff summary counts: {added, modified, deleted}."
  @type diff_summary :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @typedoc "Pre-computed data for the modeline: branch name and diff summary."
  @type modeline_info :: {branch :: String.t() | nil, diff_summary()}

  @doc """
  Returns a summary of diff sign counts: `{added, modified, deleted}`.

  Counts are derived from the per-line sign map, which is already computed
  on every buffer change. This is a cheap GenServer.call (no recomputation).
  """
  @spec summary(GenServer.server()) :: diff_summary()
  def summary(server) do
    GenServer.call(server, :summary)
  end

  @doc """
  Returns `{branch, {added, modified, deleted}}` in a single GenServer call.

  The branch name is cached on state and refreshed on init and save
  (`:invalidate_base`), so this call does zero I/O.
  """
  @spec modeline_info(GenServer.server()) :: modeline_info()
  def modeline_info(server) do
    GenServer.call(server, :modeline_info)
  end

  # ── Server Callbacks ───────────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    git_root = Keyword.fetch!(opts, :git_root)
    file_path = Keyword.fetch!(opts, :file_path)
    initial_content = Keyword.get(opts, :initial_content, "")

    rel_path = Git.relative_path(git_root, file_path)
    base_lines = load_base_lines(git_root, rel_path)
    current_lines = split_lines(initial_content)

    hunks = Diff.diff_lines(base_lines, current_lines)
    signs = Diff.signs_for_hunks(hunks)

    branch = read_branch(git_root)

    state = %{
      git_root: git_root,
      relative_path: rel_path,
      base_lines: base_lines,
      hunks: hunks,
      signs: signs,
      branch: branch
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:signs, _from, state) do
    {:reply, state.signs, state}
  end

  def handle_call(:hunks, _from, state) do
    {:reply, state.hunks, state}
  end

  def handle_call({:hunk_at, line}, _from, state) do
    {:reply, Diff.hunk_at_line(state.hunks, line), state}
  end

  def handle_call(:summary, _from, state) do
    summary = count_signs(state.signs)
    {:reply, summary, state}
  end

  def handle_call(:modeline_info, _from, state) do
    {:reply, {state.branch, count_signs(state.signs)}, state}
  end

  def handle_call(:git_root, _from, state) do
    {:reply, state.git_root, state}
  end

  def handle_call(:relative_path, _from, state) do
    {:reply, state.relative_path, state}
  end

  @impl true
  def handle_cast({:update, content}, state) do
    current_lines = split_lines(content)
    hunks = Diff.diff_lines(state.base_lines, current_lines)
    signs = Diff.signs_for_hunks(hunks)
    {:noreply, %{state | hunks: hunks, signs: signs}}
  end

  def handle_cast({:invalidate_base, content}, state) do
    base_lines = load_base_lines(state.git_root, state.relative_path)
    current_lines = split_lines(content)
    hunks = Diff.diff_lines(base_lines, current_lines)
    signs = Diff.signs_for_hunks(hunks)
    branch = read_branch(state.git_root)
    {:noreply, %{state | base_lines: base_lines, hunks: hunks, signs: signs, branch: branch}}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec count_signs(%{non_neg_integer() => Diff.hunk_type()}) :: diff_summary()
  defp count_signs(signs) do
    Enum.reduce(signs, {0, 0, 0}, fn {_line, type}, {a, m, d} ->
      case type do
        :added -> {a + 1, m, d}
        :modified -> {a, m + 1, d}
        :deleted -> {a, m, d + 1}
      end
    end)
  end

  @spec read_branch(String.t()) :: String.t() | nil
  defp read_branch(git_root) do
    case Git.current_branch(git_root) do
      {:ok, branch} -> branch
      :error -> nil
    end
  end

  @spec load_base_lines(String.t(), String.t()) :: [String.t()]
  defp load_base_lines(git_root, relative_path) do
    case Git.show_head(git_root, relative_path) do
      {:ok, content} -> split_lines(content)
      :error -> []
    end
  end

  @spec split_lines(String.t()) :: [String.t()]
  defp split_lines(""), do: []
  defp split_lines(content), do: String.split(content, "\n")
end
