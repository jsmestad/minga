defmodule Minga.Test.RecoveryCorpusProvider do
  @moduledoc """
  Deterministic barrier-controlled provider for recovery gate tests.

  Each prompt receives a scripted sequence of events. Events are emitted
  immediately until a `:barrier` step is reached; then the provider blocks
  until the test calls `release/1`. Multiple barriers in a single script
  create multi-step control points.

  Supports `compact/2` with a configurable compacted-messages response so
  recovery tests can exercise the full Session compaction path.
  """

  @behaviour MingaAgent.Provider

  use GenServer

  alias MingaAgent.Event
  alias MingaAgent.Session.Request
  alias Minga.Test.ProviderRequest

  @typedoc "One step in a scripted event sequence."
  @type script_step ::
          {:event, Event.t()}
          | {:text, String.t()}
          | {:tool_start, String.t(), String.t()}
          | {:tool_end, String.t(), String.t(), String.t()}
          | {:complete, String.t()}
          | :barrier

  @type state :: %{
          subscriber: pid(),
          test_pid: pid(),
          scripts: [[script_step()]],
          pending_script: [script_step()],
          active_request: Request.t() | nil,
          response_text: String.t(),
          compacted_messages: [ReqLLM.Message.t()] | nil,
          prompt_count: non_neg_integer()
        }

  @doc "Builds provider opts for a single-script provider."
  @spec script([script_step()]) :: keyword()
  def script(steps) when is_list(steps), do: scripts([steps])

  @doc "Builds provider opts for a multi-prompt provider with one script per prompt."
  @spec scripts([[script_step()]]) :: keyword()
  def scripts(scripts) when is_list(scripts), do: [scripts: scripts, test_pid: self()]

  @doc "Releases the provider past its current barrier."
  @spec release(GenServer.server()) :: :ok
  def release(pid) do
    GenServer.call(pid, :release_barrier)
  end

  @impl MingaAgent.Provider
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl MingaAgent.Provider
  @spec send_prompt(GenServer.server(), Request.t()) :: :ok
  def send_prompt(pid, %Request{} = request) do
    GenServer.cast(pid, {:prompt, request})
    :ok
  end

  @impl MingaAgent.Provider
  @spec abort(GenServer.server(), String.t()) :: :ok
  def abort(pid, _request_id) do
    GenServer.cast(pid, :abort)
    :ok
  end

  @impl MingaAgent.Provider
  @spec new_session(GenServer.server()) :: :ok
  def new_session(pid) do
    GenServer.cast(pid, :new_session)
    :ok
  end

  @impl MingaAgent.Provider
  @spec get_state(GenServer.server()) :: {:ok, map()}
  def get_state(_pid) do
    {:ok, %{model: nil, is_streaming: false, token_usage: nil}}
  end

  @impl MingaAgent.Provider
  @spec set_model(GenServer.server(), String.t()) :: :ok
  def set_model(_pid, _model), do: :ok

  @impl MingaAgent.Provider
  @spec compact(GenServer.server(), [ReqLLM.Message.t()]) ::
          {:ok, [ReqLLM.Message.t()], String.t()} | {:error, term()}
  def compact(pid, messages) do
    GenServer.call(pid, {:compact, messages})
  end

  @impl GenServer
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    subscriber = Keyword.fetch!(opts, :subscriber)
    test_pid = Keyword.fetch!(opts, :test_pid)

    {:ok,
     %{
       subscriber: subscriber,
       test_pid: test_pid,
       scripts: Keyword.get(opts, :scripts, []),
       pending_script: [],
       active_request: nil,
       response_text: "",
       compacted_messages: Keyword.get(opts, :compacted_messages),
       prompt_count: 0
     }}
  end

  @impl GenServer
  def handle_cast({:prompt, request}, state) do
    text = ProviderRequest.text(request)
    send(state.test_pid, {:recovery_provider_prompt, self(), text})
    send(state.test_pid, {:recovery_provider_request, self(), request})
    {script, scripts} = pop_script(state.scripts)

    state = %{
      state
      | scripts: scripts,
        active_request: request,
        response_text: "",
        prompt_count: state.prompt_count + 1
    }

    {:noreply, run_steps(script, state)}
  end

  # Abort leaves the request and any script past a barrier in place, so a test can release
  # late events tagged with the aborted request and prove the Session ignores them.
  def handle_cast(:abort, state) do
    send(state.test_pid, {:recovery_provider_abort, self()})
    {:noreply, state}
  end

  def handle_cast(:new_session, state) do
    {:noreply, %{state | pending_script: [], active_request: nil, response_text: ""}}
  end

  @impl GenServer
  def handle_call(:release_barrier, _from, state) do
    {:reply, :ok, run_steps(state.pending_script, %{state | pending_script: []})}
  end

  def handle_call({:compact, messages}, _from, state) do
    compacted = state.compacted_messages || messages
    {:reply, {:ok, compacted, "recovery test compaction summary"}, state}
  end

  @spec pop_script([[script_step()]]) :: {[script_step()], [[script_step()]]}
  defp pop_script([script | rest]), do: {script, rest}
  defp pop_script([]), do: {[], []}

  @spec run_steps([script_step()], state()) :: state()
  defp run_steps([], state), do: state

  defp run_steps([:barrier | rest], state) do
    send(state.test_pid, {:recovery_provider_barrier, self()})
    %{state | pending_script: rest}
  end

  defp run_steps([{:text, text} | rest], state) do
    emit(state, %Event.TextDelta{delta: text})
    run_steps(rest, %{state | response_text: state.response_text <> text})
  end

  defp run_steps([{:tool_start, id, name} | rest], state) do
    emit(state, %Event.ToolStart{tool_call_id: id, name: name, args: %{}})
    run_steps(rest, state)
  end

  defp run_steps([{:tool_end, id, name, result} | rest], state) do
    emit(state, %Event.ToolEnd{
      tool_call_id: id,
      name: name,
      outcome: :complete,
      result: result,
      is_error: false
    })

    run_steps(rest, state)
  end

  defp run_steps([{:complete, text} | rest], state) do
    response_text = state.response_text <> text
    complete_turn(state, response_text)
    run_steps(rest, %{state | active_request: nil, response_text: ""})
  end

  defp run_steps([{:event, event} | rest], state) do
    emit(state, event)
    run_steps(rest, state)
  end

  @spec emit(state(), Event.t()) :: :ok
  defp emit(%{subscriber: subscriber, active_request: %Request{} = request}, event) do
    ProviderRequest.emit(subscriber, request, event)
    :ok
  end

  defp emit(_state, _event), do: :ok

  @spec complete_turn(state(), String.t()) :: :ok
  defp complete_turn(
         %{subscriber: subscriber, active_request: %Request{} = request},
         text
       ) do
    ProviderRequest.complete(subscriber, request, text)
    :ok
  end
end
