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

  Call `subscribe/2` with a pid to receive `{:agent_event, session_pid, event}`
  messages. The editor uses this to update the modeline and chat panel.
  """

  use GenServer

  alias Minga.Agent.Branch
  alias Minga.Agent.Credentials
  alias Minga.Agent.Event
  alias Minga.Agent.Message
  alias Minga.Agent.Notifier
  alias Minga.Agent.ProviderResolver
  alias Minga.Agent.SessionStore

  @typedoc "Agent session status."
  @type status :: :idle | :thinking | :tool_executing | :error

  @typedoc "Pending tool approval data (nil when no approval is pending)."
  @type pending_approval ::
          %{
            tool_call_id: String.t(),
            name: String.t(),
            args: map(),
            reply_to: pid()
          }
          | nil

  @typedoc "Internal session state."
  @type state :: %{
          session_id: String.t(),
          provider: pid() | nil,
          provider_module: module(),
          provider_opts: keyword(),
          status: status(),
          messages: [Message.t()],
          subscribers: MapSet.t(pid()),
          total_usage: Event.token_usage(),
          error_message: String.t() | nil,
          pending_thinking_level: String.t() | nil,
          pending_approval: pending_approval(),
          model_name: String.t(),
          provider_name: String.t(),
          save_timer: reference() | nil,
          branches: [Branch.t()]
        }

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc "Starts a new agent session."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc """
  Sends a user prompt to the agent.

  Accepts either a plain text string or a list of ContentPart structs
  (for multi-modal messages with images).
  """
  @spec send_prompt(GenServer.server(), String.t() | [ReqLLM.Message.ContentPart.t()]) ::
          :ok | {:error, term()}
  def send_prompt(session, content) when is_binary(content) or is_list(content) do
    GenServer.call(session, {:send_prompt, content})
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

  @typedoc "Snapshot of session state needed by the editor for rendering."
  @type editor_snapshot :: %{
          status: status(),
          pending_approval: map() | nil,
          error: String.t() | nil
        }

  @doc "Returns a snapshot of session state for the editor to rebuild AgentState."
  @spec editor_snapshot(GenServer.server()) :: editor_snapshot()
  def editor_snapshot(session) do
    GenServer.call(session, :editor_snapshot)
  end

  @doc """
  Responds to a pending tool approval.

  Sends the decision directly to the Task process that is blocking
  on `receive`, then clears the pending approval and broadcasts
  the resolution to subscribers.
  """
  @spec respond_to_approval(GenServer.server(), :approve | :reject | :approve_all) :: :ok
  def respond_to_approval(session, decision) when decision in [:approve, :reject, :approve_all] do
    GenServer.call(session, {:respond_to_approval, decision})
  end

  @doc "Returns the session ID."
  @spec session_id(GenServer.server()) :: String.t()
  def session_id(session) do
    GenServer.call(session, :session_id)
  end

  @doc """
  Loads a previously saved session, replacing the current conversation history.

  The provider's conversation context is not synced; the loaded messages
  are for display only until the user sends a new prompt, which re-establishes
  the provider context.
  """
  @spec load_session(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def load_session(session, session_id) when is_binary(session_id) do
    GenServer.call(session, {:load_session, session_id})
  end

  @typedoc "Lightweight session metadata for the session picker."
  @type metadata :: %{
          id: String.t(),
          model_name: String.t(),
          created_at: DateTime.t(),
          message_count: non_neg_integer(),
          first_prompt: String.t() | nil,
          cost: float(),
          status: status()
        }

  @doc "Returns lightweight metadata about this session (for the picker)."
  @spec metadata(GenServer.server()) :: metadata()
  def metadata(session) do
    GenServer.call(session, :metadata)
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

  @doc "Manually triggers context compaction on the provider."
  @spec compact(GenServer.server()) :: {:ok, String.t()} | {:error, String.t()}
  def compact(session) do
    GenServer.call(session, :compact, 30_000)
  end

  @doc "Continues from an interrupted stream response."
  @spec continue(GenServer.server()) :: :ok | {:error, term()}
  def continue(session) do
    GenServer.call(session, :continue)
  end

  @doc "Activates a skill by name."
  @spec activate_skill(GenServer.server(), String.t()) :: {:ok, term()} | {:error, term()}
  def activate_skill(session, name) do
    GenServer.call(session, {:activate_skill, name})
  end

  @doc "Deactivates a skill by name."
  @spec deactivate_skill(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def deactivate_skill(session, name) do
    GenServer.call(session, {:deactivate_skill, name})
  end

  @doc "Lists all discovered skills and which are active."
  @spec list_skills(GenServer.server()) :: {:ok, [map()], [String.t()]} | {:error, term()}
  def list_skills(session) do
    GenServer.call(session, :list_skills)
  end

  @doc "Generates a context artifact summarizing the current session."
  @spec summarize(GenServer.server()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def summarize(session) do
    GenServer.call(session, :summarize, 60_000)
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

  @doc "Cycles to the next model in the configured rotation."
  @spec cycle_model(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def cycle_model(session) do
    GenServer.call(session, :cycle_model, 10_000)
  end

  @doc "Sets the model without resetting conversation context."
  @spec set_model(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def set_model(session, model) when is_binary(model) do
    GenServer.call(session, {:set_model, model})
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

  @doc "Branches the conversation at the given turn index."
  @spec branch_at(GenServer.server(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def branch_at(session, turn_index) when is_integer(turn_index) do
    GenServer.call(session, {:branch_at, turn_index})
  end

  @doc "Lists all conversation branches."
  @spec list_branches(GenServer.server()) :: {:ok, String.t()}
  def list_branches(session) do
    GenServer.call(session, :list_branches)
  end

  @doc "Switches to a named branch, replacing the current messages."
  @spec switch_branch(GenServer.server(), non_neg_integer()) :: :ok | {:error, String.t()}
  def switch_branch(session, branch_index) when is_integer(branch_index) do
    GenServer.call(session, {:switch_branch, branch_index})
  end

  @doc "Appends a system message to the conversation and notifies subscribers."
  @spec add_system_message(GenServer.server(), String.t(), Message.system_level()) :: :ok
  def add_system_message(session, text, level \\ :info) do
    GenServer.cast(session, {:add_system_message, text, level})
  end

  @doc "Returns the provider pid for direct provider-specific calls."
  @spec get_provider(GenServer.server()) :: pid() | nil
  def get_provider(session) do
    GenServer.call(session, :get_provider)
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

    session_id = Keyword.get(opts, :session_id, generate_session_id())
    model_name = Keyword.get(opts, :model_name, "unknown")

    provider_name =
      provider_opts
      |> Keyword.get(:provider, "unknown")
      |> to_string()

    state = %{
      session_id: session_id,
      provider: nil,
      provider_module: provider_module,
      provider_opts: provider_opts,
      status: :idle,
      messages: [Message.system("Session started · #{timestamp}")],
      subscribers: MapSet.new(),
      total_usage: %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0},
      error_message: nil,
      pending_thinking_level: initial_thinking_level,
      pending_approval: nil,
      model_name: model_name,
      provider_name: provider_name,
      save_timer: nil,
      created_at: DateTime.utc_now(),
      branches: []
    }

    # Start provider asynchronously so init doesn't block
    send(self(), :start_provider)

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:send_prompt, _text}, _from, %{provider: nil} = state) do
    {:reply, {:error, :provider_not_ready}, state}
  end

  def handle_call({:send_prompt, content}, _from, state) do
    # Add user message to conversation.
    # Content may be a plain string or a list of ContentPart structs
    # (when images are attached via @image.png mentions).
    {user_msg, send_content} = build_user_message(content)
    state = %{state | messages: state.messages ++ [user_msg]}
    state = notify_messages_changed(state)

    case state.provider_module.send_prompt(state.provider, send_content) do
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

    # Mark any running tool calls as aborted
    messages =
      Enum.map(state.messages, fn
        {:tool_call, %{status: :running} = tc} ->
          {:tool_call, %{tc | status: :error, result: "aborted", is_error: true}}

        other ->
          other
      end)

    # Append "Aborted" system message, clear any pending approval
    state = %{state | messages: messages, pending_approval: nil}
    state = append_system_message(state, "Aborted", :info)
    state = notify_messages_changed(state)
    state = set_status(state, :idle)
    {:reply, :ok, state}
  end

  def handle_call(:new_session, _from, state) do
    if state.provider do
      state.provider_module.new_session(state.provider)
    end

    timestamp = Calendar.strftime(DateTime.utc_now(), "%H:%M:%S UTC")

    state = cancel_save_timer(state)

    state = %{
      state
      | session_id: generate_session_id(),
        messages: [Message.system("Session cleared · #{timestamp}")],
        status: :idle,
        total_usage: %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0},
        error_message: nil,
        pending_approval: nil
    }

    broadcast(state, {:status_changed, :idle})
    state = notify_messages_changed(state)
    {:reply, :ok, state}
  end

  def handle_call(:session_id, _from, state) do
    {:reply, state.session_id, state}
  end

  def handle_call({:load_session, session_id}, _from, state) do
    case SessionStore.load(session_id) do
      {:ok, data} ->
        state = cancel_save_timer(state)

        state = %{
          state
          | session_id: data.id,
            messages: data.messages,
            total_usage: data.usage,
            model_name: data.model_name,
            status: :idle,
            error_message: nil,
            pending_approval: nil
        }

        broadcast(state, {:status_changed, :idle})
        state = notify_messages_changed(state)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
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

  def handle_call(:get_provider, _from, state) do
    {:reply, state.provider, state}
  end

  def handle_call(:editor_snapshot, _from, state) do
    snapshot = %{
      status: state.status,
      pending_approval: state.pending_approval,
      error: state.error_message
    }

    {:reply, snapshot, state}
  end

  def handle_call(:metadata, _from, state) do
    meta = %{
      id: state.session_id,
      model_name: state.model_name,
      created_at: state.created_at,
      message_count: length(state.messages),
      first_prompt: first_user_prompt(state.messages),
      cost: state.total_usage[:cost] || 0.0,
      status: state.status
    }

    {:reply, meta, state}
  end

  def handle_call({:respond_to_approval, _decision}, _from, %{pending_approval: nil} = state) do
    Minga.Log.warning(:agent, "[Session] respond_to_approval called with no pending approval")
    {:reply, {:error, :no_pending_approval}, state}
  end

  def handle_call({:respond_to_approval, decision}, _from, state) do
    %{tool_call_id: tool_call_id, reply_to: reply_to} = state.pending_approval

    # Send the decision directly to the blocked Task process
    send(reply_to, {:tool_approval_response, tool_call_id, decision})

    state = %{state | pending_approval: nil}
    broadcast(state, {:approval_resolved, decision})
    {:reply, :ok, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  def handle_call(:compact, _from, %{provider: nil} = state) do
    {:reply, {:error, "No active provider"}, state}
  end

  def handle_call(:compact, _from, state) do
    if function_exported?(state.provider_module, :compact, 1) do
      result = state.provider_module.compact(state.provider)
      {:reply, result, state}
    else
      {:reply, {:error, "Provider does not support compaction"}, state}
    end
  end

  def handle_call(:continue, _from, %{provider: nil} = state) do
    {:reply, {:error, "No active provider"}, state}
  end

  def handle_call(:continue, _from, state) do
    if function_exported?(state.provider_module, :continue, 1) do
      result = state.provider_module.continue(state.provider)
      {:reply, result, state}
    else
      {:reply, {:error, "Provider does not support continue"}, state}
    end
  end

  def handle_call({:activate_skill, _name}, _from, %{provider: nil} = state) do
    {:reply, {:error, "No active provider"}, state}
  end

  def handle_call({:activate_skill, name}, _from, state) do
    result = GenServer.call(state.provider, {:activate_skill, name})
    {:reply, result, state}
  end

  def handle_call({:deactivate_skill, _name}, _from, %{provider: nil} = state) do
    {:reply, {:error, "No active provider"}, state}
  end

  def handle_call({:deactivate_skill, name}, _from, state) do
    result = GenServer.call(state.provider, {:deactivate_skill, name})
    {:reply, result, state}
  end

  def handle_call(:list_skills, _from, %{provider: nil} = state) do
    {:reply, {:error, "No active provider"}, state}
  end

  def handle_call(:list_skills, _from, state) do
    result = GenServer.call(state.provider, :list_skills)
    {:reply, result, state}
  end

  def handle_call(:summarize, _from, %{provider: nil} = state) do
    {:reply, {:error, "No active provider"}, state}
  end

  def handle_call(:summarize, _from, state) do
    result = GenServer.call(state.provider, :summarize, 55_000)
    {:reply, result, state}
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

  def handle_call(:cycle_model, _from, %{provider: nil} = state) do
    {:reply, {:error, :provider_not_ready}, state}
  end

  def handle_call(:cycle_model, _from, state) do
    result = dispatch_optional(state.provider_module, :cycle_model, [state.provider])
    {:reply, result, state}
  end

  def handle_call({:set_model, _model}, _from, %{provider: nil} = state) do
    {:reply, {:error, :provider_not_ready}, state}
  end

  def handle_call({:set_model, model}, _from, state) do
    result = dispatch_optional(state.provider_module, :set_model, [state.provider, model])
    state = %{state | model_name: model}
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
    state = notify_messages_changed(state)
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
    state = notify_messages_changed(state)
    {:reply, :ok, state}
  end

  def handle_call({:branch_at, turn_index}, _from, state) do
    branch_name = "branch-#{length(state.branches) + 1}"

    case Branch.branch_at(state.messages, turn_index, branch_name, state.branches) do
      {:ok, truncated, branches} ->
        state = %{state | messages: truncated, branches: branches}
        state = notify_messages_changed(state)

        {:reply, {:ok, "Branched at turn #{turn_index}. Branch saved as '#{branch_name}'."},
         state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:list_branches, _from, state) do
    {:reply, {:ok, Branch.list(state.branches)}, state}
  end

  def handle_call({:switch_branch, branch_index}, _from, state) do
    idx = branch_index - 1

    case Enum.at(state.branches, idx) do
      nil ->
        {:reply, {:error, "Branch #{branch_index} not found. Use /branches to list."}, state}

      branch ->
        state = %{state | messages: branch.messages}
        state = notify_messages_changed(state)
        {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_cast({:add_system_message, text, level}, state) do
    state = append_system_message(state, text, level)
    state = notify_messages_changed(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:start_provider, state) do
    case start_provider(state) do
      {:ok, pid} ->
        Process.monitor(pid)
        state = %{state | provider: pid}
        state = apply_pending_thinking_level(state)
        state = maybe_show_auth_onboarding(state)
        {:noreply, state}

      {:error, reason} ->
        Minga.Log.error(:agent, "[Agent.Session] failed to start provider: #{inspect(reason)}")
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
    Minga.Log.warning(:agent, "[Agent.Session] provider process died: #{inspect(reason)}")
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

  def handle_info(:save_session, state) do
    state = %{state | save_timer: nil}
    save_to_disk(state)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Event handling ──────────────────────────────────────────────────────────

  @spec handle_provider_event(Event.t(), state()) :: state()
  defp handle_provider_event(%Event.AgentStart{}, state) do
    state = %{state | pending_approval: nil}
    set_status(state, :thinking)
  end

  defp handle_provider_event(%Event.AgentEnd{usage: usage}, state) do
    Notifier.notify(:complete, "Agent finished")

    state =
      if usage do
        log_turn_usage(usage, state)

        state = %{
          state
          | total_usage: %{
              input: state.total_usage.input + usage.input,
              output: state.total_usage.output + usage.output,
              cache_read: state.total_usage.cache_read + usage.cache_read,
              cache_write: state.total_usage.cache_write + usage.cache_write,
              cost: state.total_usage.cost + usage.cost
            },
            messages: state.messages ++ [Message.usage(usage)]
        }

        notify_messages_changed(state)
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
    broadcast(state, {:tool_started, event.name, event.args})
    notify_messages_changed(state)
  end

  defp handle_provider_event(%Event.ToolFileChanged{} = event, state) do
    broadcast(state, {:file_changed, event.path, event.before_content, event.after_content})
    state
  end

  defp handle_provider_event(%Event.ToolApproval{} = event, state) do
    Notifier.notify(:approval, "Approval needed: #{event.name}")

    approval = %{
      tool_call_id: event.tool_call_id,
      name: event.name,
      args: event.args,
      reply_to: event.reply_to
    }

    state = %{state | pending_approval: approval}
    broadcast(state, {:approval_pending, approval})
    state
  end

  defp handle_provider_event(%Event.ToolUpdate{} = event, state) do
    messages =
      update_tool_call(state.messages, event.tool_call_id, fn tc ->
        # Auto-expand on first update so the user sees live output
        %{tc | result: event.partial_result, collapsed: false}
      end)

    state = %{state | messages: messages}
    broadcast(state, {:tool_update, event.tool_call_id, event.name, event.partial_result})
    state
  end

  defp handle_provider_event(%Event.ToolEnd{} = event, state) do
    messages =
      update_tool_call(state.messages, event.tool_call_id, fn tc ->
        duration =
          if tc.started_at do
            System.monotonic_time(:millisecond) - tc.started_at
          else
            nil
          end

        %{
          tc
          | status: if(event.is_error, do: :error, else: :complete),
            result: event.result,
            is_error: event.is_error,
            collapsed: true,
            duration_ms: duration
        }
      end)

    state = %{state | messages: messages}
    status = if event.is_error, do: :error, else: :done
    broadcast(state, {:tool_ended, event.name, event.result, status})
    notify_messages_changed(state)
  end

  defp handle_provider_event(%Event.ContextUsage{} = event, state) do
    broadcast(state, {:context_usage, event.estimated_tokens, event.context_limit})
    state
  end

  defp handle_provider_event(%Event.TurnLimitReached{current: current, limit: limit}, state) do
    broadcast(state, {:turn_limit_reached, current, limit})
    state
  end

  defp handle_provider_event(%Event.Error{message: message}, state) do
    Notifier.notify(:error, message)
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
    %{state | messages: state.messages ++ [msg]}
  end

  @spec append_to_last_assistant([Message.t()], String.t()) :: [Message.t()]
  defp append_to_last_assistant(messages, delta) do
    case List.last(messages) do
      {:assistant, text} ->
        List.replace_at(messages, length(messages) - 1, {:assistant, text <> delta})

      _ ->
        messages ++ [Message.assistant(delta)]
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
        messages ++ [Message.thinking(delta)]
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
    session_pid = self()

    Enum.each(state.subscribers, fn pid ->
      send(pid, {:agent_event, session_pid, event})
    end)
  end

  # When content is a ContentPart list (images attached), extract the text
  # for the chat message and pass the full parts to the provider.
  @spec build_user_message(String.t() | [ReqLLM.Message.ContentPart.t()]) ::
          {Message.t(), String.t() | [ReqLLM.Message.ContentPart.t()]}
  defp build_user_message(content) when is_binary(content) do
    {Message.user(content), content}
  end

  defp build_user_message(parts) when is_list(parts) do
    text =
      parts
      |> Enum.filter(&(&1.type == :text))
      |> Enum.map_join("", & &1.text)

    attachments =
      parts
      |> Enum.filter(&(&1.type in [:image, :image_url]))
      |> Enum.map(fn part ->
        filename = get_in(part.metadata || %{}, [:filename]) || "image"
        size_display = get_in(part.metadata || %{}, [:size_display]) || "?"
        %{filename: filename, size_kb: parse_size_kb(size_display)}
      end)

    {Message.user(text, attachments), parts}
  end

  @spec parse_size_kb(String.t()) :: non_neg_integer()
  defp parse_size_kb(display) do
    case Integer.parse(String.replace(display, "KB", "")) do
      {kb, _} -> kb
      :error -> 0
    end
  end

  @doc false
  @spec notify_messages_changed(state()) :: state()
  defp notify_messages_changed(state) do
    broadcast(state, :messages_changed)
    schedule_save(state)
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
  # Shows an onboarding message when no API keys are configured and the
  # native provider is active. Only fires once per session.
  @spec maybe_show_auth_onboarding(map()) :: map()
  defp maybe_show_auth_onboarding(state) do
    if state.provider_module == Minga.Agent.Providers.Native and not Credentials.any_configured?() do
      msg =
        "No API keys configured. Use `/auth` to get started.\n\n" <>
          "Example: `/auth anthropic sk-ant-your-key-here`\n" <>
          "Run `/auth` with no arguments to see status for all providers."

      messages = state.messages ++ [Message.system(msg)]
      broadcast(state, {:system_message, msg, :info})
      %{state | messages: messages}
    else
      state
    end
  end

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

  # ── Session persistence ─────────────────────────────────────────────────────

  @save_debounce_ms 500

  @spec schedule_save(state()) :: state()
  defp schedule_save(state) do
    state = cancel_save_timer(state)
    ref = Process.send_after(self(), :save_session, @save_debounce_ms)
    %{state | save_timer: ref}
  end

  @spec cancel_save_timer(state()) :: state()
  defp cancel_save_timer(%{save_timer: nil} = state), do: state

  defp cancel_save_timer(%{save_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | save_timer: nil}
  end

  @spec save_to_disk(state()) :: :ok
  defp save_to_disk(state) do
    data = %{
      id: state.session_id,
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      model_name: state.model_name,
      messages: state.messages,
      usage: state.total_usage
    }

    SessionStore.save(data)
  end

  @spec generate_session_id() :: String.t()
  @spec first_user_prompt([Message.t()]) :: String.t() | nil
  defp first_user_prompt(messages) do
    Enum.find_value(messages, fn
      {:user, text} when is_binary(text) -> text
      {:user, text, _attachments} when is_binary(text) -> text
      _ -> nil
    end)
  end

  defp generate_session_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    [a, b, c, d, e]
    |> Enum.map_join("-", &Integer.to_string(&1, 16))
    |> String.downcase()
  end

  @spec log_turn_usage(map(), state()) :: :ok
  defp log_turn_usage(usage, state) do
    i = Map.get(usage, :input, 0)
    o = Map.get(usage, :output, 0)
    cr = Map.get(usage, :cache_read, 0)
    cw = Map.get(usage, :cache_write, 0)
    cost = Map.get(usage, :cost, 0.0)

    provider = titleize(state.provider_name)
    model = titleize(state.model_name)

    cache_part =
      if cr > 0 or cw > 0 do
        " cache:#{format_k(cr)}/#{format_k(cw)}"
      else
        ""
      end

    Minga.Editor.log_to_messages(
      "[Agent] #{provider}/#{model} turn: in:#{format_k(i)} out:#{format_k(o)}#{cache_part} cost:$#{Float.round(cost, 4)}"
    )
  end

  @spec format_k(number()) :: String.t()
  defp format_k(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp format_k(n), do: "#{n}"

  @spec titleize(String.t()) :: String.t()
  defp titleize(str) do
    str
    |> String.split(~r/[-_\s]+/)
    |> Enum.map_join(" ", fn word ->
      {first, rest} = String.split_at(word, 1)
      String.upcase(first) <> rest
    end)
  end

  @impl GenServer
  def terminate(reason, _state) do
    case reason do
      :normal ->
        :ok

      :shutdown ->
        :ok

      {:shutdown, _} ->
        :ok

      _ ->
        Minga.Log.error(
          :agent,
          "[Agent.Session] crashed: #{inspect(reason, pretty: true, limit: 1000)}"
        )
    end
  end
end
