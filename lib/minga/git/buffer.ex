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

  alias Minga.Buffer
  alias Minga.Core.Diff
  alias Minga.Git
  alias Minga.Git.Change
  alias Minga.Git.Metadata
  alias Minga.Git.TrackedFile
  alias Minga.Project.Root

  @typedoc "Internal state."
  @type state :: %{
          git_root: String.t(),
          file_path: String.t(),
          canonical_target: String.t() | nil,
          relative_path: String.t(),
          base: binary() | nil,
          base_lines: [String.t()],
          content: binary(),
          hunks: [Diff.hunk()],
          signs: %{non_neg_integer() => Diff.hunk_type()},
          branch: String.t() | nil,
          backend: module()
        }

  # ── Client API ─────────────────────────────────────────────────────────────

  @typedoc "Options for starting a git buffer."
  @type start_opt ::
          {:git_root, String.t()}
          | {:file_path, String.t()}
          | {:canonical_target, String.t()}
          | {:initial_content, String.t()}
          | {:backend, module()}

  @doc "Starts a git buffer for a file in a git repository."
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Recomputes the diff and returns after the tracked state is current."
  @spec update_sync(GenServer.server(), String.t()) :: :ok
  def update_sync(server, current_content) when is_binary(current_content) do
    GenServer.call(server, {:update, current_content})
  end

  @doc "Observes one buffer revision and publishes only the changed HEAD rows needed by authorship."
  @spec observe(
          GenServer.server(),
          pid(),
          {String.t(), binary(), Buffer.position(), non_neg_integer()},
          :cached_head | :refresh_head
        ) :: :ok
  def observe(server, buffer, observation, head) do
    GenServer.cast(server, {:observe, buffer, observation, head})
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

  @doc "Builds a snapshot only when the observation still names the tracked target."
  @spec tracked_file(
          GenServer.server(),
          {String.t() | nil, binary(), Buffer.position(), non_neg_integer()}
        ) :: {:ok, TrackedFile.t()} | :not_tracked
  def tracked_file(server, observation) do
    GenServer.call(server, {:tracked_file, observation})
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

  The branch name is cached on state and refreshed with the HEAD comparison, so this call does zero I/O.
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
    backend = Keyword.get(opts, :backend, Git)

    target = Keyword.get_lazy(opts, :canonical_target, fn -> Metadata.file_target(file_path) end)

    root =
      case Root.canonical_path(git_root) do
        {:ok, canonical} -> canonical
        {:error, _reason} -> Path.expand(git_root)
      end

    rel_path = Path.relative_to(target || Path.expand(file_path), root)
    base = load_base(backend, git_root, rel_path)
    base_lines = Change.lines(base)
    hunks = Diff.diff_lines(base_lines, Change.lines(initial_content))

    state = %{
      git_root: git_root,
      file_path: file_path,
      canonical_target: target,
      relative_path: rel_path,
      base: base,
      base_lines: base_lines,
      content: initial_content,
      hunks: hunks,
      signs: Diff.signs_for_hunks(hunks),
      branch: read_branch(backend, git_root),
      backend: backend
    }

    {:ok, state}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call(:signs, _from, state) do
    {:reply, state.signs, state}
  end

  def handle_call(:hunks, _from, state) do
    {:reply, state.hunks, state}
  end

  def handle_call(
        {:tracked_file, {path, content, cursor, version}},
        _from,
        %{file_path: path, canonical_target: target} = state
      )
      when is_binary(target) do
    if Metadata.file_target(path) == target do
      # Compute against the observation without moving the cache backwards.
      hunks =
        if content == state.content,
          do: state.hunks,
          else: Diff.diff_lines(state.base_lines, Change.lines(content))

      snapshot = %TrackedFile{
        root: state.git_root,
        path: state.relative_path,
        base: state.base,
        content: content,
        version: version,
        cursor: cursor,
        hunks: hunks
      }

      {:reply, {:ok, snapshot}, state}
    else
      {:reply, :not_tracked, state}
    end
  end

  def handle_call({:tracked_file, _other_path}, _from, state),
    do: {:reply, :not_tracked, state}

  def handle_call({:hunk_at, line}, _from, state) do
    {:reply, Diff.hunk_at_line(state.hunks, line), state}
  end

  def handle_call({:update, content}, _from, state) do
    {:reply, :ok, update_diff(state, content)}
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
  @spec handle_cast(term(), state()) :: {:noreply, state()}
  def handle_cast(
        {:observe, buffer, {path, content, _, version}, head},
        %{file_path: path} = state
      ) do
    state =
      case head do
        :refresh_head -> refresh_base(state, content)
        :cached_head when content == state.content -> state
        :cached_head -> update_diff(state, content)
      end

    ranges =
      if is_binary(state.base) do
        for %{start_line: first, count: count} <- state.hunks,
            count > 0,
            do: {first, first + count - 1}
      else
        :unknown
      end

    send(buffer, {:git_authorship, path, version, ranges})
    {:noreply, state}
  end

  def handle_cast({:observe, _buffer, _observation, _head}, state), do: {:noreply, state}

  # ── Private ────────────────────────────────────────────────────────────────

  @spec refresh_base(state(), binary()) :: state()
  defp refresh_base(state, content) do
    base = load_base(state.backend, state.git_root, state.relative_path)
    branch = read_branch(state.backend, state.git_root)
    update_diff(%{state | base: base, base_lines: Change.lines(base), branch: branch}, content)
  end

  @spec update_diff(state(), binary()) :: state()
  defp update_diff(state, content) do
    hunks = Diff.diff_lines(state.base_lines, Change.lines(content))
    signs = Diff.signs_for_hunks(hunks)
    %{state | content: content, hunks: hunks, signs: signs}
  end

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

  @spec read_branch(module(), String.t()) :: String.t() | nil
  defp read_branch(backend, git_root) do
    case backend.current_branch(git_root) do
      {:ok, branch} -> branch
      :error -> nil
    end
  end

  @spec load_base(module(), String.t(), String.t()) :: binary() | nil
  defp load_base(backend, git_root, relative_path) do
    case backend.show_head(git_root, relative_path) do
      {:ok, content} -> content
      :error -> nil
    end
  end
end
