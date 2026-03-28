defmodule Minga.Buffer.Fork do
  @moduledoc """
  A forked copy of a buffer for concurrent agent editing.

  When an agent session starts editing a file, a fork is created from the
  parent `Buffer.Server`. The fork holds a snapshot of the parent's Document
  at fork time (the common ancestor) and its own Document that the agent edits.
  The user continues editing the parent buffer independently.

  When the agent finishes, `merge/1` computes a three-way merge: common ancestor,
  fork changes, and current parent changes. Non-overlapping changes merge
  automatically. Overlapping changes are returned as conflicts for resolution.

  The fork exposes the same GenServer call messages as Buffer.Server for the
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
  alias Minga.Buffer.Server, as: BufServer
  alias Minga.Core.Diff

  @typedoc "Fork creation options."
  @type create_opt :: {:parent, pid()} | {:content, String.t()}

  @typedoc "Internal fork state."
  @type state :: %{
          ancestor: Document.t(),
          document: Document.t(),
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
    content = BufServer.content(parent_pid)
    start_link(parent: parent_pid, content: content)
  end

  @doc """
  Returns the full text content of the fork.
  """
  @spec content(GenServer.server()) :: String.t()
  def content(server) do
    GenServer.call(server, :content)
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
  Returns the ancestor (snapshot at fork time) content.
  """
  @spec ancestor_content(GenServer.server()) :: String.t()
  def ancestor_content(server) do
    GenServer.call(server, :ancestor_content)
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
  def handle_call(:content, _from, state) do
    {:reply, Document.content(state.document), state}
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

  def handle_call({:find_and_replace, old_text, new_text, _boundary}, _from, state) do
    content = Document.content(state.document)

    case do_find_and_replace(content, old_text, new_text) do
      {:ok, new_doc, msg} ->
        {:reply, {:ok, msg},
         %{state | document: new_doc, dirty: true, version: state.version + 1}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:replace_content, new_content, _source}, _from, state) do
    new_doc = Document.new(new_content)
    {:reply, :ok, %{state | document: new_doc, dirty: true, version: state.version + 1}}
  end

  def handle_call({:find_and_replace_batch, edits, _boundary}, _from, state) do
    {final_doc, results_reversed} =
      Enum.reduce(edits, {state.document, []}, fn
        {"", _new_text}, {doc, acc} ->
          {doc, [{:error, "old_text is empty"} | acc]}

        {old_text, new_text}, {doc, acc} ->
          content = Document.content(doc)

          case do_find_and_replace(content, old_text, new_text) do
            {:ok, new_doc, msg} -> {new_doc, [{:ok, msg} | acc]}
            {:error, _} = err -> {doc, [err | acc]}
          end
      end)

    results = Enum.reverse(results_reversed)
    any_applied = Enum.any?(results, &match?({:ok, _}, &1))

    new_state =
      if any_applied do
        %{state | document: final_doc, dirty: true, version: state.version + 1}
      else
        state
      end

    {:reply, {:ok, results}, new_state}
  end

  def handle_call(:merge, _from, %{parent_alive: false} = state) do
    {:reply, {:error, :parent_dead}, state}
  end

  def handle_call(:merge, _from, state) do
    ancestor_lines = Document.content(state.ancestor) |> String.split("\n")
    fork_lines = Document.content(state.document) |> String.split("\n")

    parent_content = BufServer.content(state.parent)
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

  @spec do_find_and_replace(String.t(), String.t(), String.t()) ::
          {:ok, Document.t(), String.t()} | {:error, String.t()}
  defp do_find_and_replace(_content, "", _new_text) do
    {:error, "old_text is empty"}
  end

  defp do_find_and_replace(content, old_text, new_text) do
    case :binary.matches(content, old_text) do
      [] ->
        {:error, "old_text not found"}

      [{offset, len}] ->
        before_match = binary_part(content, 0, offset)
        after_match = binary_part(content, offset + len, byte_size(content) - offset - len)
        new_content = before_match <> new_text <> after_match
        {:ok, Document.new(new_content), "applied"}

      matches ->
        {:error, "old_text found #{length(matches)} times (ambiguous)"}
    end
  end

  @spec format_merge_result(Diff.merge3_result()) ::
          {:ok, String.t()} | {:conflict, [Diff.merge_hunk()]}
  defp format_merge_result({:ok, lines}) do
    {:ok, Enum.join(lines, "\n")}
  end

  defp format_merge_result({:conflict, hunks}) do
    {:conflict, hunks}
  end
end
