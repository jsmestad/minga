defmodule Minga.Test.SessionPlanToolProvider do
  @behaviour MingaAgent.Provider

  use GenServer

  alias MingaAgent.Event
  alias MingaAgent.Tool.Executor
  alias MingaAgent.Tool.Registry
  alias MingaAgent.Tool.Spec

  @impl MingaAgent.Provider
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl MingaAgent.Provider
  def send_prompt(pid, _text) do
    GenServer.cast(pid, :attempt_write)
    :ok
  end

  @impl MingaAgent.Provider
  def abort(pid) do
    GenServer.cast(pid, :abort)
    :ok
  end

  @impl MingaAgent.Provider
  def new_session(pid) do
    GenServer.cast(pid, :new_session)
    :ok
  end

  @impl MingaAgent.Provider
  def seed_messages(_pid, _messages), do: :ok

  @impl MingaAgent.Provider
  def get_state(_pid), do: {:ok, %{model: nil, is_streaming: false, token_usage: nil}}

  @impl GenServer
  def init(opts) do
    subscriber = Keyword.fetch!(opts, :subscriber)
    parent = Keyword.fetch!(opts, :parent)
    registry = :"plan_tool_provider_#{System.unique_integer([:positive])}"

    :ets.new(registry, [:named_table, :set, :public, read_concurrency: true])

    spec =
      Spec.new!(
        source: :builtin,
        name: "write_file",
        description: "test write",
        parameter_schema: %{},
        callback: fn args ->
          send(parent, {:write_callback_called, args})
          {:ok, "wrote"}
        end
      )

    :ok = Registry.register(registry, spec)
    {:ok, %{subscriber: subscriber, parent: parent, registry: registry}}
  end

  @impl GenServer
  def handle_cast(:attempt_write, state) do
    result =
      Executor.execute(
        "write_file",
        %{"path" => "plan-mode.txt", "content" => "changed"},
        state.registry,
        execution_mode(MingaAgent.Session.status(state.subscriber))
      )

    maybe_emit_plan_refusal(state.subscriber, result)
    send(state.parent, {:provider_tool_result, result})
    {:noreply, state}
  end

  def handle_cast(:abort, state), do: {:noreply, state}
  def handle_cast(:new_session, state), do: {:noreply, state}

  @spec execution_mode(MingaAgent.Session.status()) :: Executor.execution_mode()
  defp execution_mode(:plan), do: :plan
  defp execution_mode(_status), do: :exec

  @spec maybe_emit_plan_refusal(pid(), Executor.result()) :: :ok
  defp maybe_emit_plan_refusal(subscriber, {:error, {:plan_mode_refused, message}}) do
    send(
      subscriber,
      {:agent_provider_event, %Event.SystemMessage{message: message, level: :info}}
    )

    :ok
  end
end
