defmodule Minga.Test.SubagentWorktreeProvider do
  @moduledoc false

  @behaviour MingaAgent.Provider

  use GenServer

  alias MingaAgent.Event

  @impl MingaAgent.Provider
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl MingaAgent.Provider
  def send_prompt(pid, text), do: GenServer.call(pid, {:prompt, text})

  @impl MingaAgent.Provider
  def abort(_pid), do: :ok

  @impl MingaAgent.Provider
  def new_session(_pid), do: :ok

  @impl MingaAgent.Provider
  def seed_messages(_pid, _messages), do: :ok

  @impl MingaAgent.Provider
  def get_state(_pid), do: {:ok, %{model: nil, is_streaming: false, token_usage: nil}}

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       subscriber: Keyword.fetch!(opts, :subscriber),
       project_root: Keyword.fetch!(opts, :project_root)
     }}
  end

  @impl GenServer
  def handle_call({:prompt, "write"}, _from, state) do
    File.write!(Path.join(state.project_root, "child.txt"), "from child\n")
    finish(state, "wrote file")
  end

  def handle_call({:prompt, "write-error"}, _from, state) do
    File.write!(Path.join(state.project_root, "child.txt"), "from child\n")
    send(state.subscriber, {:agent_provider_event, %Event.AgentStart{}})
    send(state.subscriber, {:agent_provider_event, %Event.Error{message: "failed after write"}})
    {:reply, :ok, state}
  end

  def handle_call({:prompt, _text}, _from, state), do: finish(state, "no changes")

  @spec finish(map(), String.t()) :: {:reply, :ok, map()}
  defp finish(state, text) do
    send(state.subscriber, {:agent_provider_event, %Event.AgentStart{}})
    send(state.subscriber, {:agent_provider_event, %Event.TextDelta{delta: text}})
    send(state.subscriber, {:agent_provider_event, %Event.AgentEnd{usage: nil}})
    {:reply, :ok, state}
  end
end
