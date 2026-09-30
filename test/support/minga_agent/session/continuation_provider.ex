defmodule Minga.Test.SessionContinuationProvider do
  @moduledoc false

  @behaviour MingaAgent.Provider
  use GenServer

  alias MingaAgent.Event
  alias MingaAgent.Session.Outcome
  alias MingaAgent.Session.Request
  alias Minga.Test.ProviderRequest

  @impl MingaAgent.Provider
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl MingaAgent.Provider
  @spec send_prompt(GenServer.server(), Request.t()) :: :ok
  def send_prompt(pid, %Request{} = request), do: GenServer.call(pid, {:send_prompt, request})

  @spec compact(GenServer.server(), [ReqLLM.Message.t()], keyword()) ::
          {:ok, [ReqLLM.Message.t()], String.t()} | {:error, term()}
  def compact(pid, messages, opts), do: GenServer.call(pid, {:compact, messages, opts})

  @impl MingaAgent.Provider
  @spec continue(GenServer.server(), Request.t()) :: :ok
  def continue(pid, %Request{} = request), do: GenServer.call(pid, {:send_prompt, request})

  @impl MingaAgent.Provider
  @spec abort(GenServer.server()) :: :ok
  def abort(pid), do: GenServer.call(pid, :abort)

  @impl MingaAgent.Provider
  @spec new_session(GenServer.server()) :: :ok
  def new_session(pid), do: GenServer.call(pid, :new_session)

  @impl MingaAgent.Provider
  @spec get_state(GenServer.server()) :: {:ok, map()}
  def get_state(pid), do: GenServer.call(pid, :get_state)

  @impl MingaAgent.Provider
  @spec set_model(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def set_model(pid, model), do: GenServer.call(pid, {:set_model, model})

  @spec complete(GenServer.server(), Request.t(), [ReqLLM.Message.t()]) :: :ok
  def complete(pid, %Request{} = request, messages) when is_list(messages) do
    GenServer.call(pid, {:complete, request, messages})
  end

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       subscriber: Keyword.fetch!(opts, :subscriber),
       test_pid: Keyword.fetch!(opts, :test_pid),
       requests: %{},
       model_result: Keyword.get(opts, :model_result, :ok),
       compacted_messages: Keyword.get(opts, :compacted_messages),
       system_prompt: Keyword.get(opts, :system_prompt)
     }}
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply,
     {:ok,
      %{
        model: %{id: "continuation-test"},
        is_streaming: false,
        system_prompt: state.system_prompt
      }}, state}
  end

  @impl GenServer
  def handle_call({:set_model, _model}, _from, state),
    do: {:reply, state.model_result, state}

  def handle_call({:compact, messages, _opts}, _from, state) do
    compacted_messages = state.compacted_messages || messages
    {:reply, {:ok, compacted_messages, "test context compaction"}, state}
  end

  def handle_call({:send_prompt, %Request{} = request}, _from, state) do
    send(state.test_pid, {:continuation_request, request})
    {:reply, :ok, %{state | requests: Map.put(state.requests, request.request_id, request)}}
  end

  def handle_call({:complete, %Request{} = request, messages}, _from, state) do
    case Map.pop(state.requests, request.request_id) do
      {%Request{} = ^request, requests} ->
        ProviderRequest.emit(state.subscriber, request, %Event.AgentStart{})
        ProviderRequest.emit(state.subscriber, request, %Event.TextDelta{delta: "visible answer"})

        ProviderRequest.emit(state.subscriber, request, %Event.ThinkingDelta{
          delta: "display-only"
        })

        ProviderRequest.emit(
          state.subscriber,
          request,
          %Event.ToolStart{
            tool_call_id: "display-tool-call",
            name: "read_file",
            args: %{"path" => "example.txt"}
          }
        )

        ProviderRequest.emit(
          state.subscriber,
          request,
          %Event.ToolEnd{
            tool_call_id: "display-tool-call",
            name: "read_file",
            result: "visible tool result",
            is_error: false
          }
        )

        ProviderRequest.emit(
          state.subscriber,
          request,
          %Event.AgentEnd{outcome: Outcome.new(request, messages)}
        )

        {:reply, :ok, %{state | requests: requests}}

      {_other, _requests} ->
        {:reply, {:error, :stale_request}, state}
    end
  end

  def handle_call(:abort, _from, state), do: {:reply, :ok, %{state | requests: %{}}}
  def handle_call(:new_session, _from, state), do: {:reply, :ok, %{state | requests: %{}}}
end
