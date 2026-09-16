defmodule MingaEditor.Effects.GuiSearchBuild do
  @moduledoc "Asynchronous full GUI-search index construction under latest-wins scheduling."

  @behaviour MingaEditor.Effect

  alias Minga.Buffer
  alias Minga.Buffer.SyncSnapshot
  alias Minga.Editing.Search.Index
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.Effects.GuiSearchBuild.Result
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Search

  @snapshot_timeout_ms 1_500
  @scheduler_timeout_ms 10_000

  @enforce_keys [:buffer, :query, :options, :search_revision, :select_first?]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          buffer: pid(),
          query: String.t(),
          options: Minga.Editing.Search.search_opts(),
          search_revision: non_neg_integer(),
          select_first?: boolean()
        }

  @doc "Builds a latest-wins request without placing document content in scheduler queues."
  @spec request(
          pid(),
          String.t(),
          Minga.Editing.Search.search_opts(),
          non_neg_integer(),
          boolean()
        ) ::
          Request.t()
  def request(buffer, query, options, search_revision, select_first?)
      when is_pid(buffer) and is_binary(query) and is_integer(search_revision) do
    Request.new(
      %__MODULE__{
        buffer: buffer,
        query: query,
        options: options,
        search_revision: search_revision,
        select_first?: select_first?
      },
      :gui_search,
      Policy.latest_wins(),
      timeout_ms: @scheduler_timeout_ms,
      activity: :gui_search_matching
    )
  end

  @impl true
  @spec run(t()) :: {:ok, Result.t()} | {:error, String.t()}
  def run(%__MODULE__{} = effect) do
    monitor = Process.monitor(effect.buffer)
    token = make_ref()
    :ok = Buffer.request_sync_snapshot(effect.buffer, :full, self(), token)
    await_snapshot(effect, token, monitor)
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(
        state,
        %Outcome{
          value: {:completed, %Result{} = result},
          request: %Request{effect: %__MODULE__{} = effect}
        } = outcome
      ) do
    apply_result(state, effect, result, outcome, current_revision(result.buffer))
  end

  def apply(
        state,
        %Outcome{
          value: {:failed, reason},
          request: %Request{effect: %__MODULE__{} = effect}
        } = outcome
      ) do
    message = failure_message(reason)

    case Search.fail_gui_search(
           state.workspace.search,
           effect.search_revision,
           effect.buffer,
           message
         ) do
      {:accepted, search} ->
        state = put_search(state, search)
        {NoticeWorkflow.publish(state, "Find failed: #{message}"), outcome}

      {:stale, _search} ->
        {state, Outcome.stale(outcome, :superseded_search)}
    end
  end

  def apply(state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{value: {:completed, _result}}), do: true
  def render?(%Outcome{value: {:failed, _reason}}), do: true
  def render?(%Outcome{}), do: false

  @spec await_snapshot(t(), reference(), reference()) :: {:ok, Result.t()} | {:error, String.t()}
  defp await_snapshot(effect, token, monitor) do
    receive do
      {:buffer_sync_snapshot,
       %SyncSnapshot{
         buffer: buffer,
         token: ^token,
         version: version,
         sequence: sequence,
         changes: {:full, content}
       }}
      when buffer == effect.buffer ->
        Process.demonitor(monitor, [:flush])
        lines = :binary.split(content, "\n", [:global])
        index = Index.build(lines, effect.query, effect.options)

        {:ok,
         %Result{
           buffer: buffer,
           version: version,
           sequence: sequence,
           search_revision: effect.search_revision,
           index: index
         }}

      {:DOWN, ^monitor, :process, _buffer, reason} ->
        {:error, "buffer unavailable: #{inspect(reason)}"}
    after
      @snapshot_timeout_ms ->
        Process.demonitor(monitor, [:flush])
        {:error, "buffer snapshot timed out"}
    end
  end

  @spec apply_result(
          EditorState.t(),
          t(),
          Result.t(),
          Outcome.t(),
          {non_neg_integer(), non_neg_integer()} | :unavailable
        ) :: {EditorState.t(), Outcome.t()}
  defp apply_result(
         state,
         effect,
         %Result{version: version, sequence: sequence} = result,
         outcome,
         {version, sequence}
       ) do
    case Search.accept_gui_index(
           state.workspace.search,
           result.search_revision,
           result.buffer,
           result.version,
           result.sequence,
           result.index
         ) do
      {:accepted, search} ->
        state = put_search(state, search)
        {maybe_select_first(state, effect, result.index), outcome}

      {:stale, _search} ->
        {state, Outcome.stale(outcome, :superseded_search)}
    end
  end

  defp apply_result(state, _effect, _result, outcome, _current_revision) do
    {state, Outcome.stale(outcome, :buffer_revision_changed)}
  end

  @spec current_revision(pid()) :: {non_neg_integer(), non_neg_integer()} | :unavailable
  defp current_revision(buffer) do
    Buffer.sync_revision(buffer)
  catch
    :exit, _reason -> :unavailable
  end

  @spec maybe_select_first(EditorState.t(), t(), Index.t()) :: EditorState.t()
  defp maybe_select_first(state, %__MODULE__{select_first?: false}, _index), do: state

  defp maybe_select_first(state, %__MODULE__{buffer: buffer}, index) do
    case Index.next(index, Buffer.cursor(buffer), :forward) do
      nil ->
        state

      %{line: line, col: col} ->
        Buffer.move_to(buffer, {line, col})
        state
    end
  catch
    :exit, _reason -> state
  end

  @spec put_search(EditorState.t(), Search.t()) :: EditorState.t()
  defp put_search(state, search) do
    %{state | workspace: SessionState.set_search(state.workspace, search)}
  end

  @spec failure_message(term()) :: String.t()
  defp failure_message(reason) when is_binary(reason), do: String.slice(reason, 0, 200)
  defp failure_message({:worker_exit, reason}), do: "search worker exited: #{inspect(reason)}"
  defp failure_message(reason), do: "search worker failed: #{inspect(reason)}"
end
