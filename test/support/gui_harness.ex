defmodule Minga.Test.GUIHarness do
  @moduledoc false

  use GenServer

  alias MingaEditor.Frontend.Protocol

  @type response :: map()
  @type gui_action :: {:gui_action, term()}
  @type option :: {:path, String.t()} | {:emit_select_tab, boolean()}

  @default_timeout 5_000

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec round_trip!(GenServer.server(), binary(), String.t()) :: response()
  def round_trip!(server, command, expected_type) do
    call!(server, {:round_trip, command, expected_type}, expected_type)
  end

  @spec round_trip_with_action!(GenServer.server(), binary(), String.t(), gui_action()) ::
          {response(), gui_action()}
  def round_trip_with_action!(server, command, expected_type, expected_action) do
    call!(
      server,
      {:round_trip_with_action, command, expected_type, expected_action},
      expected_type
    )
  end

  @impl GenServer
  @spec init([option()]) :: {:ok, map()}
  def init(opts) do
    Process.flag(:trap_exit, true)
    path = Keyword.fetch!(opts, :path)
    emit_select_tab = Keyword.get(opts, :emit_select_tab, false)
    port = open_port(path, emit_select_tab)
    await_ready(port)

    {:ok, %{path: path, emit_select_tab: emit_select_tab, port: port, pending: nil}}
  end

  @impl GenServer
  @spec handle_call(tuple(), GenServer.from(), map()) ::
          {:noreply, map()} | {:reply, term(), map()}
  def handle_call({:round_trip, command, expected_type}, from, %{pending: nil} = state) do
    send_command(state.port, command)

    {:noreply,
     %{
       state
       | pending: %{
           from: from,
           expected_type: expected_type,
           expected_action: nil,
           action: nil,
           response: nil
         }
     }}
  end

  def handle_call(
        {:round_trip_with_action, command, expected_type, expected_action},
        from,
        %{pending: nil} = state
      ) do
    send_command(state.port, command)

    {:noreply,
     %{
       state
       | pending: %{
           from: from,
           expected_type: expected_type,
           expected_action: expected_action,
           action: nil,
           response: nil
         }
     }}
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :request_in_flight}, state}
  end

  @impl GenServer
  @spec handle_info(term(), map()) :: {:noreply, map()}
  def handle_info({port, {:data, data}}, %{port: port, pending: pending} = state)
      when not is_nil(pending) do
    handle_response(data, state)
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply, restart_tainted_harness({:unexpected_response, data}, state)}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    {:noreply, restart_tainted_harness({:harness_exited, reason}, state)}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @spec call!(GenServer.server(), tuple(), String.t()) :: response() | {response(), gui_action()}
  defp call!(server, request, expected_type) do
    case GenServer.call(server, request, @default_timeout) do
      {:ok, result} ->
        result

      {:error, reason} ->
        raise "GUI harness expected #{expected_type}, received #{inspect(reason)}"
    end
  end

  @spec handle_response(binary(), map()) :: {:noreply, map()}
  defp handle_response(data, %{pending: %{expected_type: expected_type} = pending} = state) do
    case JSON.decode(data) do
      {:ok, %{"type" => ^expected_type} = response} ->
        finish_response(response, pending, state)

      {:ok, %{"type" => type}} ->
        reject_response({:unexpected_response_type, type, expected_type}, state)

      {:ok, response} ->
        reject_response({:response_missing_type, response}, state)

      {:error, _reason} ->
        handle_action(data, pending, state)
    end
  end

  @spec handle_action(binary(), map(), map()) :: {:noreply, map()}
  defp handle_action(data, %{expected_action: nil}, state) do
    reject_response({:unexpected_binary_response, data}, state)
  end

  defp handle_action(data, %{expected_action: expected_action} = pending, state) do
    case Protocol.decode_event(data) do
      {:ok, ^expected_action} -> finish_response(nil, %{pending | action: expected_action}, state)
      other -> reject_response({:unexpected_gui_action, other, expected_action}, state)
    end
  end

  @spec finish_response(response() | nil, map(), map()) :: {:noreply, map()}
  defp finish_response(response, pending, state) do
    response = response || pending.response
    pending = if is_map(response), do: %{pending | response: response}, else: pending

    if is_map(pending.response) and
         (is_nil(pending.expected_action) or pending.action == pending.expected_action) do
      result =
        if is_nil(pending.expected_action),
          do: pending.response,
          else: {pending.response, pending.action}

      GenServer.reply(pending.from, {:ok, result})
      {:noreply, %{state | pending: nil}}
    else
      {:noreply, %{state | pending: pending}}
    end
  end

  @spec reject_response(term(), map()) :: {:noreply, map()}
  defp reject_response(reason, %{pending: %{from: from}} = state) do
    GenServer.reply(from, {:error, reason})
    {:noreply, restart_tainted_harness(reason, %{state | pending: nil})}
  end

  @spec restart_tainted_harness(term(), map()) :: map()
  defp restart_tainted_harness(_reason, state) do
    close_port(state.port)
    port = open_port(state.path, state.emit_select_tab)
    await_ready(port)
    %{state | port: port, pending: nil}
  end

  @spec open_port(String.t(), boolean()) :: port()
  defp open_port(path, emit_select_tab) do
    args = if emit_select_tab, do: [{:args, [~c"--emit-select-tab"]}], else: []
    Port.open({:spawn_executable, path}, [:binary, {:packet, 4} | args])
  end

  @spec await_ready(port()) :: :ok
  defp await_ready(port) do
    receive do
      {^port, {:data, ready_json}} ->
        case JSON.decode(ready_json) do
          {:ok, %{"type" => "ready"}} -> :ok
          other -> raise "GUI harness did not send ready: #{inspect(other)}"
        end
    after
      @default_timeout -> raise "GUI harness did not become ready"
    end
  end

  @spec send_command(port(), binary()) :: :ok
  defp send_command(port, command) do
    true = Port.command(port, command)
    :ok
  end

  @spec close_port(port()) :: :ok
  defp close_port(port) do
    if Port.info(port) != nil do
      Port.close(port)
    end

    :ok
  end
end
