defmodule Minga.Test.RemoteControlEditor do
  @moduledoc false

  use GenServer

  @spec start_link(pid()) :: GenServer.on_start()
  def start_link(parent) do
    GenServer.start(__MODULE__, parent, name: MingaEditor)
  end

  @impl GenServer
  def init(parent), do: {:ok, parent}

  @impl GenServer
  def handle_call({:api_execute_command, :detach_remote_session}, _from, parent) do
    send(parent, :detached)
    {:reply, :ok, parent}
  end

  def handle_call(message, _from, parent) do
    send(parent, {:unexpected_call, message})
    {:reply, :ok, parent}
  end
end
