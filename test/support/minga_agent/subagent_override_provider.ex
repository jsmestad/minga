defmodule Minga.Test.SubagentOverrideProvider do
  @moduledoc false

  @behaviour MingaAgent.Provider

  alias Minga.Test.SubagentRecordingProvider

  @spec start_link(keyword()) :: GenServer.on_start()
  @impl MingaAgent.Provider
  def start_link(opts), do: SubagentRecordingProvider.start_link(opts)

  @spec send_prompt(GenServer.server(), String.t()) :: :ok
  @impl MingaAgent.Provider
  def send_prompt(pid, text), do: SubagentRecordingProvider.send_prompt(pid, text)

  @spec abort(GenServer.server()) :: :ok
  @impl MingaAgent.Provider
  def abort(pid), do: SubagentRecordingProvider.abort(pid)

  @spec new_session(GenServer.server()) :: :ok
  @impl MingaAgent.Provider
  def new_session(pid), do: SubagentRecordingProvider.new_session(pid)

  @spec seed_messages(GenServer.server(), [term()]) :: :ok
  @impl MingaAgent.Provider
  def seed_messages(_pid, _messages), do: :ok

  @spec get_state(GenServer.server()) :: {:ok, map()}
  @impl MingaAgent.Provider
  def get_state(pid), do: SubagentRecordingProvider.get_state(pid)
end
