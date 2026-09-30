defmodule Minga.Test.SubagentWorktreeProvider do
  @moduledoc false

  @behaviour MingaAgent.Provider

  use GenServer

  alias MingaAgent.Event
  alias Minga.Test.ProviderRequest

  @impl MingaAgent.Provider
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl MingaAgent.Provider
  def send_prompt(pid, request), do: GenServer.call(pid, {:prompt, request})

  @impl MingaAgent.Provider
  def abort(_pid), do: :ok

  @impl MingaAgent.Provider
  def new_session(_pid), do: :ok

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
  def handle_call({:prompt, request}, _from, state) do
    case ProviderRequest.text(request) do
      "write" ->
        File.write!(Path.join(state.project_root, "child.txt"), "from child\n")
        finish(state, request, "wrote file")

      "write-error" ->
        File.write!(Path.join(state.project_root, "child.txt"), "from child\n")
        ProviderRequest.emit(state.subscriber, request, %Event.AgentStart{})

        ProviderRequest.emit(
          state.subscriber,
          request,
          %Event.Error{message: "failed after write"}
        )

        {:reply, :ok, state}

      _other ->
        finish(state, request, "no changes")
    end
  end

  @spec finish(map(), MingaAgent.Session.Request.t(), String.t()) :: {:reply, :ok, map()}
  defp finish(state, request, text) do
    ProviderRequest.emit(state.subscriber, request, %Event.AgentStart{})
    ProviderRequest.emit(state.subscriber, request, %Event.TextDelta{delta: text})
    ProviderRequest.complete(state.subscriber, request, text)
    {:reply, :ok, state}
  end
end
