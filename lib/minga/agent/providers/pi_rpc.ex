defmodule Minga.Agent.Providers.PiRpc do
  @moduledoc """
  Pi RPC provider for AI agent integration.

  Spawns `pi --mode rpc` as an OS-level Port process and communicates via
  JSON lines over stdin/stdout. This is the same isolation pattern as the
  Zig renderer port: two OS processes, no shared memory, supervised by
  the BEAM.

  Pi handles LLM calls, tool execution, context management, and
  auto-compaction. This module translates between pi's JSON event
  protocol and Minga's `Agent.Event` structs.
  """

  @behaviour Minga.Agent.Provider

  use GenServer

  require Logger

  alias Minga.Agent.Event

  @typedoc "Internal state for the Pi RPC provider."
  @type state :: %{
          port: port() | nil,
          subscriber: pid(),
          pi_path: String.t(),
          model: String.t() | nil,
          buffer: String.t(),
          request_id: non_neg_integer()
        }

  # ── Provider callbacks ──────────────────────────────────────────────────────

  @impl Minga.Agent.Provider
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl Minga.Agent.Provider
  @spec send_prompt(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def send_prompt(pid, text) when is_binary(text) do
    GenServer.call(pid, {:send_prompt, text})
  end

  @impl Minga.Agent.Provider
  @spec abort(GenServer.server()) :: :ok
  def abort(pid) do
    GenServer.call(pid, :abort)
  end

  @impl Minga.Agent.Provider
  @spec new_session(GenServer.server()) :: :ok | {:error, term()}
  def new_session(pid) do
    GenServer.call(pid, :new_session)
  end

  @impl Minga.Agent.Provider
  @spec get_state(GenServer.server()) ::
          {:ok, Minga.Agent.Provider.session_state()} | {:error, term()}
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  @impl Minga.Agent.Provider
  @doc "Fetches available models from the pi RPC backend."
  @spec get_available_models(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def get_available_models(pid) do
    GenServer.call(pid, :get_available_models, 10_000)
  end

  @impl Minga.Agent.Provider
  @doc "Fetches available commands (extensions, skills, prompts) from pi."
  @spec get_commands(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def get_commands(pid) do
    GenServer.call(pid, :get_commands, 10_000)
  end

  @doc "Sets the thinking level on the pi backend."
  @spec set_thinking_level(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def set_thinking_level(pid, level) when is_binary(level) do
    GenServer.call(pid, {:set_thinking_level, level})
  end

  @doc "Cycles to the next thinking level on the pi backend."
  @spec cycle_thinking_level(GenServer.server()) :: {:ok, String.t() | nil} | {:error, term()}
  def cycle_thinking_level(pid) do
    GenServer.call(pid, :cycle_thinking_level, 10_000)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl GenServer
  @spec init(keyword()) :: {:ok, state()} | {:stop, term()}
  def init(opts) do
    subscriber = Keyword.fetch!(opts, :subscriber)
    pi_path = Keyword.get(opts, :pi_path) || find_pi()
    provider = Keyword.get(opts, :provider)
    model = Keyword.get(opts, :model)

    case pi_path do
      nil ->
        {:stop,
         {:pi_not_found,
          "pi binary not found on $PATH. Install: npm i -g @mariozechner/pi-coding-agent"}}

      path ->
        state = %{
          port: nil,
          subscriber: subscriber,
          pi_path: path,
          provider: provider,
          model: model,
          buffer: "",
          request_id: 0,
          pending: %{}
        }

        case spawn_pi(state) do
          {:ok, port} ->
            {:ok, %{state | port: port}}

          {:error, reason} ->
            {:stop, reason}
        end
    end
  end

  @impl GenServer
  def handle_call({:send_prompt, text}, _from, state) do
    {id, state} = next_id(state)

    command = %{
      "id" => "req-#{id}",
      "type" => "prompt",
      "message" => text
    }

    case send_command(state.port, command) do
      :ok -> {:reply, :ok, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call(:abort, _from, state) do
    command = %{"type" => "abort"}
    send_command(state.port, command)
    {:reply, :ok, state}
  end

  def handle_call(:new_session, _from, state) do
    command = %{"type" => "new_session"}

    case send_command(state.port, command) do
      :ok -> {:reply, :ok, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call(:get_state, from, state) do
    send_request(state, "get_state", from)
  end

  def handle_call(:get_available_models, from, state) do
    send_request(state, "get_available_models", from)
  end

  def handle_call(:get_commands, from, state) do
    send_request(state, "get_commands", from)
  end

  def handle_call({:set_thinking_level, level}, _from, state) do
    {id, state} = next_id(state)
    command = %{"id" => "req-#{id}", "type" => "set_thinking_level", "level" => level}

    case send_command(state.port, command) do
      :ok -> {:reply, :ok, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call(:cycle_thinking_level, from, state) do
    send_request(state, "cycle_thinking_level", from)
  end

  @impl GenServer
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    handle_line(line, state)
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[Agent.PiRpc] pi process exited with status #{status}")
    notify(state.subscriber, %Event.Error{message: "pi process exited (status #{status})"})
    {:stop, {:pi_exited, status}, %{state | port: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.close(port)
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec spawn_pi(state()) :: {:ok, port()} | {:error, term()}
  defp spawn_pi(state) do
    args = ["--mode", "rpc", "--no-session"]

    args =
      case state.provider do
        nil -> args
        provider -> args ++ ["--provider", provider]
      end

    args =
      case state.model do
        nil -> args
        model -> args ++ ["--model", model]
      end

    try do
      port =
        Port.open({:spawn_executable, state.pi_path}, [
          :binary,
          :exit_status,
          :use_stdio,
          {:line, 1_048_576},
          {:args, args},
          {:cd, project_root()},
          {:env, env_vars()}
        ])

      {:ok, port}
    rescue
      e -> {:error, {:spawn_failed, Exception.message(e)}}
    end
  end

  @spec env_vars() :: [{charlist(), charlist()}]
  defp env_vars do
    # Pass through relevant env vars
    for {key, val} <- System.get_env(),
        key in ~w(HOME PATH ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY NODE_PATH),
        do: {String.to_charlist(key), String.to_charlist(val)}
  end

  @spec send_command(port() | nil, map()) :: :ok | {:error, :no_port}
  @spec send_request(map(), String.t(), GenServer.from()) :: {:noreply, map()}
  defp send_request(state, type, from) do
    {id, state} = next_id(state)
    req_id = "req-#{id}"
    command = %{"id" => req_id, "type" => type}

    case send_command(state.port, command) do
      :ok ->
        state = %{state | pending: Map.put(state.pending, req_id, from)}
        {:noreply, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @spec project_root() :: String.t()
  defp project_root do
    case Minga.Project.root() do
      nil -> File.cwd!()
      root -> root
    end
  catch
    :exit, _ -> File.cwd!()
  end

  defp send_command(nil, _command), do: {:error, :no_port}

  defp send_command(port, command) do
    json = JSON.encode!(command)
    Logger.info("[Agent → Pi] #{json}")
    Port.command(port, [json, "\n"])
    :ok
  end

  @spec handle_line(binary(), state()) :: {:noreply, state()}
  defp handle_line(line, state) do
    full_line = state.buffer <> line
    state = %{state | buffer: ""}

    # Pi sometimes prepends OSC terminal notifications (e.g. ]777;notify;...)
    # to a JSON line. Strip everything before the first '{'.
    json_line = strip_to_json(full_line)

    case JSON.decode(json_line) do
      {:ok, event} ->
        log_received_event(event)
        handle_event(event, state)

      {:error, _} ->
        Logger.debug("[Agent.PiRpc] ignoring non-JSON line: #{String.slice(full_line, 0, 100)}")
        {:noreply, state}
    end
  end

  @spec log_received_event(map()) :: :ok
  defp log_received_event(%{
         "type" => "message_update",
         "assistantMessageEvent" => %{"type" => sub_type} = delta
       }) do
    summary =
      case sub_type do
        "text_delta" -> "text_delta: #{String.slice(delta["delta"] || "", 0, 80)}"
        "thinking_delta" -> "thinking_delta: #{String.slice(delta["delta"] || "", 0, 80)}"
        other -> other
      end

    Logger.info("[Pi → Agent] message_update/#{summary}")
  end

  defp log_received_event(%{"type" => "response", "command" => cmd, "success" => success} = event) do
    error = if event["error"], do: " error=#{event["error"]}", else: ""
    Logger.info("[Pi → Agent] response cmd=#{cmd} success=#{success}#{error}")
  end

  defp log_received_event(%{"type" => "extension_ui_request", "method" => method} = event) do
    Logger.info("[Pi → Agent] extension_ui_request method=#{method} id=#{event["id"]}")
  end

  defp log_received_event(%{"type" => type}) do
    Logger.info("[Pi → Agent] #{type}")
  end

  defp log_received_event(_), do: :ok

  @spec strip_to_json(String.t()) :: String.t()
  defp strip_to_json(line) do
    case :binary.match(line, "{") do
      {pos, _} -> binary_part(line, pos, byte_size(line) - pos)
      :nomatch -> line
    end
  end

  @spec handle_event(map(), state()) :: {:noreply, state()}
  defp handle_event(%{"type" => "agent_start"}, state) do
    notify(state.subscriber, %Event.AgentStart{})
    {:noreply, state}
  end

  defp handle_event(%{"type" => "agent_end"} = event, state) do
    usage = extract_usage(event)
    notify(state.subscriber, %Event.AgentEnd{usage: usage})
    {:noreply, state}
  end

  defp handle_event(%{"type" => "message_update", "assistantMessageEvent" => delta}, state) do
    handle_delta(delta, state)
  end

  defp handle_event(%{"type" => "tool_execution_start"} = event, state) do
    notify(state.subscriber, %Event.ToolStart{
      tool_call_id: event["toolCallId"] || "",
      name: event["toolName"] || "unknown",
      args: event["args"] || %{}
    })

    {:noreply, state}
  end

  defp handle_event(%{"type" => "tool_execution_update"} = event, state) do
    partial =
      case get_in(event, ["partialResult", "content"]) do
        [%{"text" => text} | _] -> text
        _ -> ""
      end

    notify(state.subscriber, %Event.ToolUpdate{
      tool_call_id: event["toolCallId"] || "",
      name: event["toolName"] || "unknown",
      partial_result: partial
    })

    {:noreply, state}
  end

  defp handle_event(%{"type" => "tool_execution_end"} = event, state) do
    result =
      case get_in(event, ["result", "content"]) do
        [%{"text" => text} | _] -> text
        _ -> ""
      end

    notify(state.subscriber, %Event.ToolEnd{
      tool_call_id: event["toolCallId"] || "",
      name: event["toolName"] || "unknown",
      result: result,
      is_error: event["isError"] == true
    })

    {:noreply, state}
  end

  defp handle_event(%{"type" => "response", "id" => id} = event, state) when is_binary(id) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        # No pending caller (e.g. prompt ack) — ignore
        {:noreply, state}

      {from, pending} ->
        state = %{state | pending: pending}

        reply =
          if event["success"] do
            {:ok, event["data"]}
          else
            {:error, event["error"] || "unknown error"}
          end

        GenServer.reply(from, reply)
        {:noreply, state}
    end
  end

  defp handle_event(%{"type" => "response"}, state) do
    # Response without id — prompt ack, abort ack, etc.
    {:noreply, state}
  end

  defp handle_event(%{"type" => "extension_ui_request", "method" => method, "id" => id}, state)
       when method in ["select", "confirm", "input", "editor"] do
    # Dialog methods block pi until we respond. Auto-cancel for now.
    Logger.info("[Agent.PiRpc] auto-cancelling dialog: #{method} (id=#{id})")
    response = %{"type" => "extension_ui_response", "id" => id, "cancelled" => true}
    send_command(state.port, response)
    {:noreply, state}
  end

  defp handle_event(%{"type" => "extension_ui_request"}, state) do
    # Fire-and-forget methods (setStatus, notify, setWidget, etc.) — ignore
    {:noreply, state}
  end

  defp handle_event(%{"type" => "extension_error"} = event, state) do
    Logger.warning("[Agent.PiRpc] extension error: #{event["error"]}")
    {:noreply, state}
  end

  defp handle_event(%{"type" => type}, state) do
    Logger.debug("[Agent.PiRpc] unhandled event type: #{type}")
    {:noreply, state}
  end

  defp handle_event(_event, state) do
    {:noreply, state}
  end

  @spec handle_delta(map(), state()) :: {:noreply, state()}
  defp handle_delta(%{"type" => "text_delta", "delta" => delta}, state) do
    notify(state.subscriber, %Event.TextDelta{delta: delta})
    {:noreply, state}
  end

  defp handle_delta(%{"type" => "thinking_delta", "delta" => delta}, state) do
    notify(state.subscriber, %Event.ThinkingDelta{delta: delta})
    {:noreply, state}
  end

  defp handle_delta(_delta, state) do
    {:noreply, state}
  end

  @spec extract_usage(map()) :: Event.token_usage() | nil
  defp extract_usage(%{"messages" => messages}) when is_list(messages) do
    # Sum usage across all assistant messages in the agent_end event
    messages
    |> Enum.filter(fn m -> m["role"] == "assistant" && is_map(m["usage"]) end)
    |> Enum.reduce(nil, fn msg, acc ->
      usage = msg["usage"]
      cost_map = usage["cost"] || %{}

      current = %{
        input: usage["input"] || 0,
        output: usage["output"] || 0,
        cache_read: usage["cacheRead"] || 0,
        cache_write: usage["cacheWrite"] || 0,
        cost: cost_map["total"] || 0.0
      }

      case acc do
        nil ->
          current

        prev ->
          %{
            input: prev.input + current.input,
            output: prev.output + current.output,
            cache_read: prev.cache_read + current.cache_read,
            cache_write: prev.cache_write + current.cache_write,
            cost: prev.cost + current.cost
          }
      end
    end)
  end

  defp extract_usage(_), do: nil

  @spec notify(pid(), Event.t()) :: Event.t()
  defp notify(subscriber, event) do
    send(subscriber, {:agent_provider_event, event})
    event
  end

  @spec next_id(state()) :: {non_neg_integer(), state()}
  defp next_id(state) do
    id = state.request_id + 1
    {id, %{state | request_id: id}}
  end

  @spec find_pi() :: String.t() | nil
  defp find_pi do
    System.find_executable("pi")
  end
end
