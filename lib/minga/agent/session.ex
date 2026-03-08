defmodule Minga.Agent.Session do
  @moduledoc """
  Manages the lifecycle of one AI agent conversation.

  The session holds conversation history, tracks agent status, and
  coordinates between the provider (pi RPC, etc.) and the editor UI.
  It runs as a supervised GenServer under `Agent.Supervisor`, so a
  crash here never affects buffers or the editor.

  ## Status lifecycle

      :idle → :thinking → :tool_executing → :thinking → ... → :idle
                 ↓                              ↓
              :error                          :error

  ## Subscribing to events

  Call `subscribe/2` with a pid to receive `{:agent_event, event}`
  messages. The editor uses this to update the modeline and chat panel.
  """

  use GenServer

  require Logger

  alias Minga.Agent.Event
  alias Minga.Agent.Message
  alias Minga.Agent.ProviderResolver

  @typedoc "Agent session status."
  @type status :: :idle | :thinking | :tool_executing | :error

  @typedoc "Internal session state."
  @type state :: %{
          provider: pid() | nil,
          provider_module: module(),
          provider_opts: keyword(),
          status: status(),
          messages: [Message.t()],
          subscribers: MapSet.t(pid()),
          total_usage: Event.token_usage(),
          error_message: String.t() | nil,
          pending_thinking_level: String.t() | nil
        }

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc "Starts a new agent session."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc "Sends a user prompt to the agent."
  @spec send_prompt(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def send_prompt(session, text) when is_binary(text) do
    GenServer.call(session, {:send_prompt, text})
  end

  @doc "Aborts the current agent operation."
  @spec abort(GenServer.server()) :: :ok
  def abort(session) do
    GenServer.call(session, :abort)
  end

  @doc "Starts a fresh conversation."
  @spec new_session(GenServer.server()) :: :ok | {:error, term()}
  def new_session(session) do
    GenServer.call(session, :new_session)
  end

  @doc "Returns the current session status."
  @spec status(GenServer.server()) :: status()
  def status(session) do
    GenServer.call(session, :status)
  end

  @doc "Returns the conversation messages."
  @spec messages(GenServer.server()) :: [Message.t()]
  def messages(session) do
    GenServer.call(session, :messages)
  end

  @doc "Returns accumulated token usage."
  @spec usage(GenServer.server()) :: Event.token_usage()
  def usage(session) do
    GenServer.call(session, :usage)
  end

  @doc "Subscribes the calling process to session events."
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(session) do
    GenServer.call(session, {:subscribe, self()})
  end

  @doc "Unsubscribes the calling process from session events."
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(session) do
    GenServer.call(session, {:unsubscribe, self()})
  end

  @doc "Fetches available models from the provider."
  @spec get_available_models(GenServer.server()) :: {:ok, term()} | {:error, term()}
  def get_available_models(session) do
    GenServer.call(session, :get_available_models, 10_000)
  end

  @doc "Fetches available commands from the provider."
  @spec get_commands(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def get_commands(session) do
    GenServer.call(session, :get_commands, 10_000)
  end

  @doc "Sets the thinking level on the provider."
  @spec set_thinking_level(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def set_thinking_level(session, level) when is_binary(level) do
    GenServer.call(session, {:set_thinking_level, level})
  end

  @doc "Cycles to the next thinking level."
  @spec cycle_thinking_level(GenServer.server()) :: {:ok, term()} | {:error, term()}
  def cycle_thinking_level(session) do
    GenServer.call(session, :cycle_thinking_level, 10_000)
  end

  @doc "Toggles the collapsed state of a tool call message."
  @spec toggle_tool_collapse(GenServer.server(), non_neg_integer()) :: :ok
  def toggle_tool_collapse(session, message_index) do
    GenServer.call(session, {:toggle_tool_collapse, message_index})
  end

  @doc "Toggles all tool call messages between collapsed and expanded."
  @spec toggle_all_tool_collapses(GenServer.server()) :: :ok
  def toggle_all_tool_collapses(session) do
    GenServer.call(session, :toggle_all_tool_collapses)
  end

  @doc "Appends a system message to the conversation and notifies subscribers."
  @spec add_system_message(GenServer.server(), String.t(), Message.system_level()) :: :ok
  def add_system_message(session, text, level \\ :info) do
    GenServer.cast(session, {:add_system_message, text, level})
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl GenServer
  @dialyzer {:no_contracts, init: 1}
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    provider_module = resolve_provider_module(opts)

    provider_opts =
      Keyword.merge(
        [subscriber: self()],
        Keyword.get(opts, :provider_opts, [])
      )

    initial_thinking_level = Keyword.get(opts, :thinking_level)
    timestamp = Calendar.strftime(DateTime.utc_now(), "%H:%M:%S UTC")

    state = %{
      provider: nil,
      provider_module: provider_module,
      provider_opts: provider_opts,
      status: :idle,
      messages: [Message.system("Session started · #{timestamp}")],
      subscribers: MapSet.new(),
      total_usage: %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0},
      error_message: nil,
      pending_thinking_level: initial_thinking_level
    }

    # Start provider asynchronously so init doesn't block
    send(self(), :start_provider)

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:send_prompt, _text}, _from, %{provider: nil} = state) do
    {:reply, {:error, :provider_not_ready}, state}
  end

  def handle_call({:send_prompt, text}, _from, state) do
    # Add user message to conversation
    state = %{state | messages: Enum.reverse([Message.user(text) | Enum.reverse(state.messages)])}

    case state.provider_module.send_prompt(state.provider, text) do
      :ok ->
        {:reply, :ok, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(:abort, _from, %{provider: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:abort, _from, state) do
    state.provider_module.abort(state.provider)
    state = set_status(state, :idle)
    {:reply, :ok, state}
  end

  def handle_call(:new_session, _from, state) do
    if state.provider do
      state.provider_module.new_session(state.provider)
    end

    timestamp = Calendar.strftime(DateTime.utc_now(), "%H:%M:%S UTC")

    state = %{
      state
      | messages: [Message.system("Session cleared · #{timestamp}")],
        status: :idle,
        total_usage: %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0},
        error_message: nil
    }

    broadcast(state, {:status_changed, :idle})
    broadcast(state, :messages_changed)
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call(:messages, _from, state) do
    {:reply, state.messages, state}
  end

  def handle_call(:usage, _from, state) do
    {:reply, state.total_usage, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  def handle_call(:get_available_models, _from, %{provider: nil} = state) do
    {:reply, {:error, :provider_not_ready}, state}
  end

  def handle_call(:get_available_models, _from, state) do
    result = state.provider_module.get_available_models(state.provider)
    {:reply, result, state}
  end

  def handle_call(:get_commands, _from, %{provider: nil} = state) do
    {:reply, {:error, :provider_not_ready}, state}
  end

  def handle_call(:get_commands, _from, state) do
    result = state.provider_module.get_commands(state.provider)
    {:reply, result, state}
  end

  def handle_call({:set_thinking_level, _level}, _from, %{provider: nil} = state) do
    {:reply, {:error, :provider_not_ready}, state}
  end

  def handle_call({:set_thinking_level, level}, _from, state) do
    result =
      dispatch_optional(state.provider_module, :set_thinking_level, [state.provider, level])

    {:reply, result, state}
  end

  def handle_call(:cycle_thinking_level, _from, %{provider: nil} = state) do
    {:reply, {:error, :provider_not_ready}, state}
  end

  def handle_call(:cycle_thinking_level, _from, state) do
    result = dispatch_optional(state.provider_module, :cycle_thinking_level, [state.provider])
    {:reply, result, state}
  end

  def handle_call({:toggle_tool_collapse, index}, _from, state) do
    messages =
      List.update_at(state.messages, index, fn
        {:tool_call, tc} -> {:tool_call, %{tc | collapsed: !tc.collapsed}}
        {:thinking, text, collapsed} -> {:thinking, text, !collapsed}
        other -> other
      end)

    state = %{state | messages: messages}
    broadcast(state, :messages_changed)
    {:reply, :ok, state}
  end

  def handle_call(:toggle_all_tool_collapses, _from, state) do
    # If any tool call is collapsed, expand all; otherwise collapse all.
    any_collapsed =
      Enum.any?(state.messages, fn
        {:tool_call, %{collapsed: true}} -> true
        {:thinking, _, true} -> true
        _ -> false
      end)

    target = !any_collapsed

    messages =
      Enum.map(state.messages, fn
        {:tool_call, tc} -> {:tool_call, %{tc | collapsed: target}}
        {:thinking, text, _} -> {:thinking, text, target}
        other -> other
      end)

    state = %{state | messages: messages}
    broadcast(state, :messages_changed)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:add_system_message, text, level}, state) do
    state = append_system_message(state, text, level)
    broadcast(state, :messages_changed)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:start_provider, state) do
    case start_provider(state) do
      {:ok, pid} ->
        Process.monitor(pid)
        state = %{state | provider: pid}
        state = apply_pending_thinking_level(state)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("[Agent.Session] failed to start provider: #{inspect(reason)}")
        state = set_status(state, :error)
        state = %{state | error_message: format_error(reason)}
        broadcast(state, {:error, state.error_message})
        {:noreply, state}
    end
  end

  def handle_info({:agent_provider_event, event}, state) do
    state = handle_provider_event(event, state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{provider: pid} = state) do
    Logger.warning("[Agent.Session] provider process died: #{inspect(reason)}")
    state = set_status(state, :error)
    state = %{state | provider: nil, error_message: "Agent provider crashed"}
    broadcast(state, {:error, state.error_message})

    # Try to restart the provider after a brief delay
    Process.send_after(self(), :start_provider, 2000)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # A subscriber died, remove it
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Event handling ──────────────────────────────────────────────────────────

  @spec handle_provider_event(Event.t(), state()) :: state()
  defp handle_provider_event(%Event.AgentStart{}, state) do
    set_status(state, :thinking)
  end

  defp handle_provider_event(%Event.AgentEnd{usage: usage}, state) do
    state =
      if usage do
        %{
          state
          | total_usage: %{
              input: state.total_usage.input + usage.input,
              output: state.total_usage.output + usage.output,
              cache_read: state.total_usage.cache_read + usage.cache_read,
              cache_write: state.total_usage.cache_write + usage.cache_write,
              cost: state.total_usage.cost + usage.cost
            }
        }
      else
        state
      end

    set_status(state, :idle)
  end

  defp handle_provider_event(%Event.TextDelta{delta: delta}, state) do
    # Auto-collapse any expanded thinking blocks (thinking is done)
    messages = collapse_thinking_blocks(state.messages)
    messages = append_to_last_assistant(messages, delta)
    state = %{state | messages: messages}
    broadcast(state, {:text_delta, delta})
    state
  end

  defp handle_provider_event(%Event.ThinkingDelta{delta: delta}, state) do
    messages = append_to_last_thinking(state.messages, delta)
    state = %{state | messages: messages}
    broadcast(state, {:thinking_delta, delta})
    state
  end

  defp handle_provider_event(%Event.ToolStart{} = event, state) do
    msg = Message.tool_call(event.tool_call_id, event.name, event.args)
    state = %{state | messages: Enum.reverse([msg | Enum.reverse(state.messages)])}
    state = set_status(state, :tool_executing)
    broadcast(state, :messages_changed)
    state
  end

  defp handle_provider_event(%Event.ToolUpdate{} = event, state) do
    messages =
      update_tool_call(state.messages, event.tool_call_id, fn tc ->
        %{tc | result: event.partial_result}
      end)

    state = %{state | messages: messages}
    broadcast(state, {:tool_update, event.tool_call_id})
    state
  end

  defp handle_provider_event(%Event.ToolEnd{} = event, state) do
    messages =
      update_tool_call(state.messages, event.tool_call_id, fn tc ->
        %{
          tc
          | status: if(event.is_error, do: :error, else: :complete),
            result: event.result,
            is_error: event.is_error
        }
      end)

    state = %{state | messages: messages}
    broadcast(state, :messages_changed)
    state
  end

  defp handle_provider_event(%Event.Error{message: message}, state) do
    state = set_status(state, :error)
    state = %{state | error_message: message}
    state = append_system_message(state, "Error: #{message}", :error)
    broadcast(state, {:error, message})
    state
  end

  # ── Message list helpers ────────────────────────────────────────────────────

  @spec append_system_message(state(), String.t(), Message.system_level()) :: state()
  defp append_system_message(state, text, level) do
    msg = Message.system(text, level)
    %{state | messages: Enum.reverse([msg | Enum.reverse(state.messages)])}
  end

  @spec append_to_last_assistant([Message.t()], String.t()) :: [Message.t()]
  defp append_to_last_assistant(messages, delta) do
    case List.last(messages) do
      {:assistant, text} ->
        List.replace_at(messages, length(messages) - 1, {:assistant, text <> delta})

      _ ->
        Enum.reverse([Message.assistant(delta) | Enum.reverse(messages)])
    end
  end

  @spec collapse_thinking_blocks([Message.t()]) :: [Message.t()]
  defp collapse_thinking_blocks(messages) do
    Enum.map(messages, fn
      {:thinking, text, false} -> {:thinking, text, true}
      other -> other
    end)
  end

  @spec append_to_last_thinking([Message.t()], String.t()) :: [Message.t()]
  defp append_to_last_thinking(messages, delta) do
    case List.last(messages) do
      {:thinking, text, _collapsed} ->
        List.replace_at(messages, length(messages) - 1, {:thinking, text <> delta, false})

      _ ->
        Enum.reverse([Message.thinking(delta) | Enum.reverse(messages)])
    end
  end

  @spec update_tool_call([Message.t()], String.t(), (Message.tool_call() -> Message.tool_call())) ::
          [Message.t()]
  defp update_tool_call(messages, tool_call_id, updater) do
    Enum.map(messages, fn
      {:tool_call, %{id: ^tool_call_id} = tc} -> {:tool_call, updater.(tc)}
      other -> other
    end)
  end

  # ── Status management ──────────────────────────────────────────────────────

  @spec set_status(state(), status()) :: state()
  defp set_status(state, new_status) do
    state = %{state | status: new_status}
    broadcast(state, {:status_changed, new_status})
    state
  end

  # ── Broadcasting ────────────────────────────────────────────────────────────

  @spec broadcast(state(), term()) :: :ok
  defp broadcast(state, event) do
    Enum.each(state.subscribers, fn pid ->
      send(pid, {:agent_event, event})
    end)
  end

  # ── Provider startup ────────────────────────────────────────────────────────

  @spec start_provider(state()) :: {:ok, pid()} | {:error, term()}
  defp start_provider(state) do
    state.provider_module.start_link(state.provider_opts)
  end

  @spec format_error(term()) :: String.t()
  defp format_error({:pi_not_found, msg}), do: msg
  defp format_error({:spawn_failed, msg}), do: "Failed to start agent: #{msg}"
  defp format_error(reason), do: inspect(reason)

  @spec apply_pending_thinking_level(state()) :: state()
  defp apply_pending_thinking_level(%{pending_thinking_level: nil} = state), do: state

  defp apply_pending_thinking_level(%{pending_thinking_level: level} = state) do
    try do
      dispatch_optional(state.provider_module, :set_thinking_level, [state.provider, level])
    catch
      :exit, _ -> :ok
    end

    %{state | pending_thinking_level: nil}
  end

  # Calls an optional callback on the provider module. Returns `{:error, :not_supported}`
  # if the provider doesn't implement the callback.
  @spec dispatch_optional(module(), atom(), [term()]) :: term()
  defp dispatch_optional(module, function, args) do
    if function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      {:error, :not_supported}
    end
  end

  # Determines which provider module to use. If an explicit `:provider` option is
  # passed (common in tests and from the existing code), use that. Otherwise, delegate
  # to the ProviderResolver which checks config and pi availability.
  @spec resolve_provider_module(keyword()) :: module()
  defp resolve_provider_module(opts) do
    case Keyword.fetch(opts, :provider) do
      {:ok, module} when is_atom(module) -> module
      _ -> ProviderResolver.resolve().module
    end
  end
end
