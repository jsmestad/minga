defmodule MingaAgent.Providers.RecordingProvider do
  @moduledoc false

  @behaviour MingaAgent.Provider

  use GenServer

  @impl MingaAgent.Provider
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl MingaAgent.Provider
  @spec send_prompt(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def send_prompt(_pid, _text), do: :ok

  @impl MingaAgent.Provider
  @spec abort(GenServer.server()) :: :ok
  def abort(_pid), do: :ok

  @impl MingaAgent.Provider
  @spec new_session(GenServer.server()) :: :ok | {:error, term()}
  def new_session(_pid), do: :ok

  @impl MingaAgent.Provider
  @spec get_state(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def get_state(_pid) do
    {:ok,
     %{
       model: %{id: "test-model", name: "Test Model", provider: "test"},
       is_streaming: false,
       token_usage: nil
     }}
  end

  @impl MingaAgent.Provider
  @spec get_available_models(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def get_available_models(_pid), do: {:ok, []}

  @impl MingaAgent.Provider
  @spec get_commands(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def get_commands(_pid), do: {:ok, []}

  @impl MingaAgent.Provider
  @spec set_thinking_level(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def set_thinking_level(_pid, _level), do: :ok

  @impl MingaAgent.Provider
  @spec cycle_thinking_level(GenServer.server()) :: {:ok, term()} | {:error, term()}
  def cycle_thinking_level(_pid), do: {:ok, "off"}

  @impl MingaAgent.Provider
  @spec cycle_model(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def cycle_model(_pid), do: {:ok, %{id: "test-model"}}

  @impl MingaAgent.Provider
  @spec set_model(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def set_model(_pid, _model), do: :ok

  @impl GenServer
  def init(opts) do
    test_pid = Keyword.get(opts, :test_pid)
    project_root = Keyword.get(opts, :project_root)
    subscriber = Keyword.get(opts, :subscriber)

    if is_pid(subscriber), do: Process.monitor(subscriber)
    {:ok, %{test_pid: test_pid, project_root: project_root, refreshes: []}}
  end

  @impl GenServer
  def handle_call({:refresh_project_view, project_view}, _from, state) do
    if is_pid(state.test_pid), do: send(state.test_pid, {:provider_refresh, project_view})
    {:reply, :ok, %{state | refreshes: [project_view | state.refreshes]}}
  end

  def handle_call(_msg, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_cast(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
