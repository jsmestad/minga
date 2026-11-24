defmodule Minga.Test.HeldStartProvider do
  @moduledoc """
  An agent provider whose start waits until the test releases it.

  The Session starts its provider inside its own `:start_provider` message, so while this provider is held, every call to the Session waits behind provider start. `init/1` tells the `:test_pid` from the provider options that it is held; `release/1` lets the start finish.
  """

  @behaviour MingaAgent.Provider

  use GenServer

  @doc "Lets a held provider start finish."
  @spec release(pid()) :: :ok
  def release(provider) when is_pid(provider) do
    send(provider, :release)
    :ok
  end

  @impl MingaAgent.Provider
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl MingaAgent.Provider
  def send_prompt(_pid, _request), do: :ok

  @impl MingaAgent.Provider
  def abort(_pid), do: :ok

  @impl MingaAgent.Provider
  def new_session(_pid), do: :ok

  @impl MingaAgent.Provider
  def get_state(_pid), do: {:ok, %{model: nil, is_streaming: false, token_usage: nil}}

  @impl MingaAgent.Provider
  def set_model(_pid, _model), do: :ok

  @impl GenServer
  def init(opts) do
    send(Keyword.fetch!(opts, :test_pid), {:provider_start_held, self()})

    receive do
      :release -> {:ok, %{}}
    end
  end

  @impl GenServer
  def handle_call(_msg, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_cast(_msg, state), do: {:noreply, state}
end
