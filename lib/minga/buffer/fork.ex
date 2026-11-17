defmodule Minga.Buffer.Fork do
  @moduledoc """
  A forked copy of a buffer for concurrent agent editing.

  When an agent session starts editing a file, a fork is created from the
  parent `Buffer.Process`. The fork holds a snapshot of the parent's Document
  at fork time (the common ancestor) and its own Document that the agent edits.
  The user continues editing the parent buffer independently.

  When the agent finishes, `merge/1` computes a three-way merge: common ancestor,
  fork changes, and current parent changes. Non-overlapping changes merge
  automatically. Overlapping changes are returned as conflicts for resolution.

  The fork exposes the same GenServer call messages as Buffer.Process for the
  editing subset (content, find_and_replace, replace_content, etc.), so agent
  tools can call it without knowing whether they're talking to a fork or a
  real buffer.

  ## Lifecycle

      parent_pid ──→ Fork.create(parent_pid) ──→ fork_pid
                                                    │
                                  agent edits ◀─────┘
                                                    │
                                Fork.merge(fork_pid) ──→ {:ok, merged} | {:conflict, hunks}
  """

  use GenServer

  alias Minga.Buffer.Document
  alias Minga.Buffer.FileMutation
  alias Minga.Buffer.Lines
  alias Minga.Buffer.Replace
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.Diff

  @typedoc "Fork creation options."
  @type create_opt :: {:parent, pid()} | {:content, String.t()}

  @typedoc "Internal fork state."
  @type state :: %{
          ancestor: Document.t(),
          document: Document.t(),
          deleted: boolean(),
          undo: [{Document.t(), boolean(), boolean()}],
          phase: :editing | :published,
          parent: pid(),
          parent_monitor: reference(),
          parent_alive: boolean(),
          version: non_neg_integer(),
          dirty: boolean()
        }

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Creates a fork from an existing buffer.

  Snapshots the parent's current Document as the common ancestor and creates
  an independent copy for editing. The fork monitors the parent buffer.
  """
  @spec create(pid()) :: {:ok, pid()} | {:error, term()}
  def create(parent_pid) when is_pid(parent_pid) do
    content = BufferProcess.content(parent_pid)
    start_link(parent: parent_pid, content: content)
  end

  @doc """
  Returns the full text content of the fork.
  """
  @spec content(GenServer.server()) :: String.t() | {:error, :enoent}
  def content(server) do
    GenServer.call(server, :content)
  end

  @doc "Reads the fork's logical file, including an explicit absence after deletion."
  @spec read_file(GenServer.server()) :: {:ok, String.t()} | {:error, :enoent}
  def read_file(server), do: GenServer.call(server, :read_file)

  @doc "Returns whether this fork's logical file is present or deleted."
  @spec status(GenServer.server()) :: :present | :deleted
  def status(server), do: GenServer.call(server, :status)

  @doc "Whether publication has sealed this fork against further mutations."
  @spec published?(GenServer.server()) :: boolean()
  def published?(server), do: GenServer.call(server, :published?, :infinity)

  @doc "Undoes one complete fork mutation, including deletion."
  @spec undo(GenServer.server()) :: :ok | {:error, :nothing_to_undo | :published}
  def undo(server), do: GenServer.call(server, :undo)

  @doc "Returns content and mutation version atomically in one call."
  @spec content_with_version(GenServer.server()) ::
          {String.t(), non_neg_integer()} | {:error, :enoent}
  def content_with_version(server), do: GenServer.call(server, :content_with_version)
  @doc "Returns a byte-bounded prefix, mutation version, and whether it is the whole fork."
  @spec content_prefix_with_version(GenServer.server(), non_neg_integer()) ::
          {binary(), non_neg_integer(), boolean()} | {:error, :enoent}
  def content_prefix_with_version(server, max_bytes) when max_bytes >= 0 do
    GenServer.call(server, {:content_prefix_with_version, max_bytes})
  end

  @doc "Returns a byte-bounded line range, total lines, and mutation version atomically."
  @spec content_on_lines_with_version(
          GenServer.server(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {String.t(), non_neg_integer(), pos_integer(), non_neg_integer(), boolean()}
          | {:error, :enoent}
  def content_on_lines_with_version(server, start_line, line_count, max_bytes)
      when start_line >= 0 and line_count >= 0 and max_bytes >= 0 do
    GenServer.call(
      server,
      {:content_on_lines_with_version, start_line, line_count, max_bytes}
    )
  end

  @doc """
  Computes a three-way merge between the ancestor, fork, and current parent.

  Returns `{:ok, merged_text}` when all changes merge cleanly, or
  `{:conflict, merge_hunks}` when overlapping changes exist.
  Returns `{:error, reason}` if the parent buffer is dead.
  """
  @spec merge(GenServer.server()) ::
          {:ok, String.t()} | {:conflict, [Diff.merge_hunk()]} | {:error, term()}
  def merge(server) do
    GenServer.call(server, :merge)
  end

  @doc """
  Publishes a parent merge, optionally staging the raw fork draft first.
  The staging callback runs under parent ownership before installation; failure
  leaves the parent unchanged and the fork available for recovery.
  """
  @spec publish(
          GenServer.server(),
          (String.t() -> :ok | {:conflict, term()} | {:error, term()}) | nil
        ) :: {:ok, String.t()} | {:conflict, term()} | {:error, term()}
  def publish(server, staging \\ nil) when is_nil(staging) or is_function(staging, 1) do
    GenServer.call(server, {:publish, staging}, :infinity)
  end

  @doc "Publishes a tombstone under fork and parent ownership; the caller discards it only on success."
  @spec publish_deletion(
          GenServer.server(),
          (-> :ok | {:conflict, term()} | {:error, term()})
        ) :: :ok | {:conflict, term()} | {:error, term()}
  def publish_deletion(server, publication) when is_function(publication, 0) do
    GenServer.call(server, {:publish_deletion, publication}, :infinity)
  end

  @doc "Validates the full fork revision and commits an entire file mutation in one transition."
  @spec conditional_mutate(
          GenServer.server(),
          FileMutation.expectation(),
          FileMutation.operation(),
          FileMutation.identity()
        ) :: :ok | {:error, term()}
  def conditional_mutate(server, expected, operation, identity) do
    GenServer.call(server, {:conditional_mutate, expected, operation, identity}, :infinity)
  end

  @doc """
  Returns the ancestor (snapshot at fork time) content.
  """
  @spec ancestor_content(GenServer.server()) :: String.t()
  def ancestor_content(server) do
    GenServer.call(server, :ancestor_content)
  end

  @doc "Replaces the entire content of the fork."
  @spec replace_content(GenServer.server(), String.t()) :: :ok | {:error, :enoent | :published}
  def replace_content(server, content) when is_binary(content) do
    GenServer.call(server, {:replace_content, content, :agent})
  end

  @doc "Finds and replaces text in the fork. Returns `{:ok, msg}` or `{:error, reason}`."
  @spec find_and_replace(GenServer.server(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t() | :enoent | :published}
  def find_and_replace(server, old_text, new_text) do
    GenServer.call(server, {:find_and_replace, old_text, new_text, nil})
  end

  @doc "Whether the fork has been edited since creation."
  @spec dirty?(GenServer.server()) :: boolean()
  def dirty?(server) do
    GenServer.call(server, :dirty?)
  end

  @doc "Monotonic version counter."
  @spec version(GenServer.server()) :: non_neg_integer()
  def version(server) do
    GenServer.call(server, :version)
  end

  # ── GenServer lifecycle ─────────────────────────────────────────────────────

  @spec start_link([create_opt()]) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    parent = Keyword.fetch!(opts, :parent)
    content = Keyword.fetch!(opts, :content)

    ref = Process.monitor(parent)
    doc = Document.new(content)

    state = %{
      ancestor: doc,
      document: doc,
      deleted: false,
      undo: [],
      phase: :editing,
      parent: parent,
      parent_monitor: ref,
      parent_alive: true,
      version: 0,
      dirty: false
    }

    {:ok, state}
  end

  # ── handle_call: editing subset ─────────────────────────────────────────────

  @impl true
  def handle_call(message, _from, %{phase: :published} = state)
      when message == :undo or
             elem(message, 0) in [
               :conditional_mutate,
               :replace_content,
               :find_and_replace,
               :publish,
               :publish_deletion
             ] do
    {:reply, {:error, :published}, state}
  end

  def handle_call(:published?, _from, state), do: {:reply, state.phase == :published, state}

  def handle_call(:status, _from, %{deleted: true} = state),
    do: {:reply, :deleted, state}

  def handle_call(:status, _from, state), do: {:reply, :present, state}

  def handle_call(:read_file, _from, state), do: {:reply, file_source(state), state}

  def handle_call(message, _from, %{deleted: true} = state)
      when message in [:content, :content_with_version] do
    {:reply, {:error, :enoent}, state}
  end

  def handle_call({:content_prefix_with_version, _max_bytes}, _from, %{deleted: true} = state) do
    {:reply, {:error, :enoent}, state}
  end

  def handle_call(
        {:content_on_lines_with_version, _start, _count, _max_bytes},
        _from,
        %{deleted: true} = state
      ) do
    {:reply, {:error, :enoent}, state}
  end

  def handle_call(:undo, _from, %{undo: []} = state) do
    {:reply, {:error, :nothing_to_undo}, state}
  end

  def handle_call(:undo, _from, %{undo: [{document, deleted, dirty} | rest]} = state) do
    new_state = %{
      state
      | document: document,
        deleted: deleted,
        dirty: dirty,
        undo: rest,
        version: state.version + 1
    }

    {:reply, :ok, new_state}
  end

  def handle_call(:content, _from, state) do
    {:reply, Document.content(state.document), state}
  end

  def handle_call(:content_with_version, _from, state) do
    {:reply, {Document.content(state.document), state.version}, state}
  end

  def handle_call({:content_prefix_with_version, max_bytes}, _from, state) do
    total = Document.content_byte_size(state.document)
    count = min(total, max_bytes)
    prefix = Document.slice_byte_range(state.document, 0, count)
    {:reply, {prefix, state.version, count == total}, state}
  end

  def handle_call(
        {:content_on_lines_with_version, start_line, line_count, max_bytes},
        _from,
        state
      ) do
    {content, selected_count, total, complete?} =
      Lines.bounded_contents(state.document, start_line, line_count, max_bytes)

    {:reply, {content, selected_count, total, state.version, complete?}, state}
  end

  def handle_call(:ancestor_content, _from, state) do
    {:reply, Document.content(state.ancestor), state}
  end

  def handle_call(:dirty?, _from, state) do
    {:reply, state.dirty, state}
  end

  def handle_call(:version, _from, state) do
    {:reply, state.version, state}
  end

  def handle_call({:find_and_replace, _old, _new, _boundary}, _from, %{deleted: true} = state) do
    {:reply, {:error, :enoent}, state}
  end

  def handle_call({:replace_content, _new_content, _source}, _from, %{deleted: true} = state) do
    {:reply, {:error, :enoent}, state}
  end

  def handle_call({:find_and_replace, old_text, new_text, boundary}, _from, state) do
    case Replace.apply(state.document, old_text, new_text, boundary) do
      {:ok, new_doc, msg} ->
        {:reply, {:ok, msg}, commit_fork(state, new_doc, false)}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:replace_content, new_content, _source}, _from, state) do
    new_doc = Document.new(new_content)
    {:reply, :ok, commit_fork(state, new_doc, false)}
  end

  def handle_call({:conditional_mutate, expected, operation, identity}, _from, state) do
    generation = mutation_generation(identity, state)

    case FileMutation.prepare(file_source(state), generation, identity, expected, operation) do
      {:ok, new_content} when is_binary(new_content) ->
        new_doc = Document.new(new_content)
        {:reply, :ok, commit_fork(state, new_doc, false)}

      {:ok, :deleted} ->
        {:reply, :ok, commit_fork(state, state.document, true)}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:publish_deletion, _publication}, _from, %{parent_alive: false} = state) do
    {:reply, {:error, :parent_dead}, state}
  end

  def handle_call({:publish_deletion, _publication}, _from, %{deleted: false} = state) do
    {:reply, {:error, :not_deleted}, state}
  end

  def handle_call({:publish_deletion, publication}, _from, state) do
    result =
      BufferProcess.publish_fork_deletion(
        state.parent,
        Document.content(state.ancestor),
        publication
      )

    case result do
      :ok -> {:reply, :ok, %{state | phase: :published}}
      _failure -> {:reply, result, state}
    end
  catch
    :exit, _reason ->
      {:reply, {:error, :parent_dead}, %{state | parent_alive: false}}
  end

  def handle_call(:merge, _from, %{deleted: true} = state) do
    {:reply, {:error, :deletion_publication_required}, state}
  end

  def handle_call({:publish, _staging}, _from, %{deleted: true} = state) do
    {:reply, {:error, :deletion_publication_required}, state}
  end

  def handle_call({:publish, _staging}, _from, %{parent_alive: false} = state) do
    {:reply, {:error, :parent_dead}, state}
  end

  def handle_call({:publish, _staging}, _from, %{dirty: false} = state) do
    {:reply, {:ok, Document.content(state.document)}, %{state | phase: :published}}
  end

  def handle_call({:publish, staging}, _from, state) do
    result =
      BufferProcess.merge_fork(
        state.parent,
        Document.content(state.ancestor),
        Document.content(state.document),
        staging
      )

    case result do
      {:ok, _merged} -> {:reply, result, %{state | phase: :published}}
      _failure -> {:reply, result, state}
    end
  catch
    :exit, _ ->
      {:reply, {:error, :parent_dead}, %{state | parent_alive: false}}
  end

  def handle_call(:merge, _from, %{parent_alive: false} = state) do
    {:reply, {:error, :parent_dead}, state}
  end

  def handle_call(:merge, _from, state) do
    ancestor_lines = Document.content(state.ancestor) |> String.split("\n")
    fork_lines = Document.content(state.document) |> String.split("\n")

    parent_content = BufferProcess.content(state.parent)
    parent_lines = String.split(parent_content, "\n")

    result = Diff.merge3(ancestor_lines, fork_lines, parent_lines)
    {:reply, format_merge_result(result), state}
  catch
    :exit, _ ->
      {:reply, {:error, :parent_dead}, %{state | parent_alive: false}}
  end

  # ── handle_info ─────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{parent_monitor: ref} = state) do
    {:noreply, %{state | parent_alive: false}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec file_source(state()) :: FileMutation.source()
  defp file_source(%{deleted: true}), do: {:error, :enoent}
  defp file_source(state), do: {:ok, Document.content(state.document)}

  @spec commit_fork(state(), Document.t(), boolean()) :: state()
  defp commit_fork(state, document, deleted) do
    undo = [{state.document, state.deleted, state.dirty} | state.undo]

    %{
      state
      | document: document,
        deleted: deleted,
        undo: undo,
        dirty: true,
        version: state.version + 1
    }
  end

  @spec mutation_generation(FileMutation.identity(), state()) :: non_neg_integer() | nil
  defp mutation_generation({:project_view, _source_id}, _state), do: nil
  defp mutation_generation(_identity, state), do: state.version

  @spec format_merge_result(Diff.merge3_result()) ::
          {:ok, String.t()} | {:conflict, [Diff.merge_hunk()]}
  defp format_merge_result({:ok, lines}) do
    {:ok, Enum.join(lines, "\n")}
  end

  defp format_merge_result({:conflict, hunks}) do
    {:conflict, hunks}
  end
end
