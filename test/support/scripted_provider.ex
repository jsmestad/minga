defmodule Minga.Test.ScriptedProvider do
  @moduledoc """
  Deterministic provider used by agent workflow conformance tests.

  The script lives at the `MingaAgent.Provider` seam: prompts enter through
  `send_prompt/2`, events are sent to the configured session subscriber, and
  aborts go through the provider callback. This keeps tests on the real session
  and editor event path without network calls or user config.
  """

  @behaviour MingaAgent.Provider

  use GenServer

  alias MingaAgent.Event

  @type script_step :: {:event, Event.t()} | :wait_for_abort | :wait_for_continue | :crash
  @type state :: %{
          subscriber: pid() | nil,
          owner: pid(),
          scripts: [[script_step()]],
          current_script: [script_step()],
          waiting_for_abort?: boolean(),
          waiting_for_continue?: boolean()
        }

  @doc "Builds provider options for a scripted provider instance."
  @spec script([script_step()]) :: keyword()
  def script(script) when is_list(script), do: scripts([script])

  @doc "Builds provider options for a scripted provider instance with one script per prompt."
  @spec scripts([[script_step()]]) :: keyword()
  def scripts(scripts) when is_list(scripts), do: [scripts: scripts, owner: self()]

  @doc "Resumes a script blocked at `:wait_for_continue`."
  @spec continue(GenServer.server()) :: :ok
  def continue(pid) do
    GenServer.cast(pid, :continue)
    :ok
  end

  @impl MingaAgent.Provider
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl MingaAgent.Provider
  @spec send_prompt(GenServer.server(), String.t()) :: :ok
  def send_prompt(pid, text) when is_binary(text) do
    GenServer.cast(pid, {:send_prompt, text})
    :ok
  end

  @impl MingaAgent.Provider
  @spec abort(GenServer.server()) :: :ok
  def abort(pid) do
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
  @spec seed_messages(GenServer.server(), [MingaAgent.Message.t()]) :: :ok
  def seed_messages(_pid, _messages), do: :ok

  @impl MingaAgent.Provider
  @spec get_state(GenServer.server()) :: {:ok, map()}
  def get_state(_pid) do
    {:ok,
     %{
       model: %{id: "scripted-test", name: "Scripted Test", provider: "test"},
       is_streaming: false,
       token_usage: nil
     }}
  end

  @impl MingaAgent.Provider
  @spec get_available_models(GenServer.server()) :: {:ok, [map()]}
  def get_available_models(_pid), do: {:ok, []}

  @impl MingaAgent.Provider
  @spec get_commands(GenServer.server()) :: {:ok, [map()]}
  def get_commands(_pid), do: {:ok, []}

  @impl MingaAgent.Provider
  @spec set_thinking_level(GenServer.server(), String.t()) :: :ok
  def set_thinking_level(_pid, _level), do: :ok

  @impl MingaAgent.Provider
  @spec cycle_thinking_level(GenServer.server()) :: {:ok, String.t()}
  def cycle_thinking_level(_pid), do: {:ok, "off"}

  @impl MingaAgent.Provider
  @spec cycle_model(GenServer.server()) :: {:ok, map()}
  def cycle_model(_pid), do: {:ok, %{id: "scripted-test"}}

  @impl MingaAgent.Provider
  @spec set_model(GenServer.server(), String.t()) :: :ok
  def set_model(_pid, _model), do: :ok

  @impl GenServer
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    subscriber = Keyword.get(opts, :subscriber)
    if is_pid(subscriber), do: Process.monitor(subscriber)

    {:ok,
     %{
       subscriber: subscriber,
       owner: Keyword.fetch!(opts, :owner),
       scripts: Keyword.get(opts, :scripts, [Keyword.get(opts, :script, [])]),
       current_script: [],
       waiting_for_abort?: false,
       waiting_for_continue?: false
     }}
  end

  @impl GenServer
  def handle_cast({:send_prompt, text}, state) do
    send(state.owner, {:scripted_provider_prompt, self(), text})
    {script, scripts} = next_script(state.scripts)

    state = %{
      state
      | scripts: scripts,
        current_script: [],
        waiting_for_abort?: false,
        waiting_for_continue?: false
    }

    {:noreply, run_script(script, state)}
  end

  def handle_cast(:abort, state) do
    send(state.owner, {:scripted_provider_abort, self()})

    {:noreply,
     %{state | current_script: [], waiting_for_abort?: false, waiting_for_continue?: false}}
  end

  def handle_cast(:continue, state) do
    {:noreply,
     state.current_script
     |> run_script(%{state | current_script: [], waiting_for_continue?: false})}
  end

  def handle_cast(:new_session, state) do
    {:noreply,
     %{state | current_script: [], waiting_for_abort?: false, waiting_for_continue?: false}}
  end

  @impl GenServer
  def handle_call({:refresh_project_view, _project_view}, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec next_script([[script_step()]]) :: {[script_step()], [[script_step()]]}
  defp next_script([script | rest]), do: {script, rest}
  defp next_script([]), do: {[], []}

  @spec run_script([script_step()], state()) :: state()
  defp run_script([], state), do: state

  defp run_script([{:event, event} | rest], state) do
    emit(state, event)
    run_script(rest, state)
  end

  defp run_script([:wait_for_abort | rest], state) do
    %{state | current_script: rest, waiting_for_abort?: true}
  end

  defp run_script([:wait_for_continue | rest], state) do
    %{state | current_script: rest, waiting_for_continue?: true}
  end

  defp run_script([:crash | _rest], _state) do
    raise "scripted provider crashed"
  end

  @spec emit(state(), Event.t()) :: :ok
  defp emit(%{subscriber: subscriber}, event) when is_pid(subscriber) do
    send(subscriber, {:agent_provider_event, event})
    :ok
  end

  defp emit(_state, _event), do: :ok
end
