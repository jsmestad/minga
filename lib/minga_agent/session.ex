defmodule MingaAgent.Session do
  @moduledoc """
  Manages the lifecycle of one AI agent conversation.

  The session holds conversation history, tracks agent status, and
  coordinates between the provider and the editor UI. It runs as a
  supervised GenServer under `Agent.Supervisor`, so a crash here never
  affects buffers or the editor.

  ## Status lifecycle

      :idle → :thinking → :tool_executing → :thinking → ... → :idle
                 ↓                              ↓
              :error                          :error

  ## Subscribing to events

  Call `subscribe/2` with a pid to receive `{:agent_event, session_pid, event}`
  messages. The editor uses this to update the modeline and chat panel.
  """

  use GenServer

  alias MingaAgent.Branch
  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Credentials
  alias MingaAgent.Event
  alias MingaAgent.EventLog
  alias MingaAgent.Hooks.Dispatcher, as: HookDispatcher
  alias MingaAgent.Hooks.SessionEndPayload
  alias MingaAgent.Hooks.SessionStartPayload
  alias MingaAgent.Hooks.NotificationPayload
  alias MingaAgent.Hooks.Result, as: HookResult
  alias MingaAgent.Hooks.StopPayload
  alias MingaAgent.Hooks.UserPromptSubmitPayload
  alias MingaAgent.Memory
  alias MingaAgent.Message
  alias MingaAgent.Notifier
  alias MingaAgent.ProviderResolver
  alias MingaAgent.SessionMetadata
  alias MingaAgent.SessionStore
  alias MingaAgent.EditBoundary
  alias MingaAgent.SubagentContext
  alias MingaAgent.ToolCall
  alias MingaAgent.TurnUsage

  @typedoc "Agent session status."
  @type status :: :idle | :plan | :thinking | :tool_executing | :error

  @typedoc "Pending tool approval data."
  @type pending_approval :: MingaAgent.ToolApproval.t()

  @typedoc "Tool trust lifetime."
  @type trust_scope :: :session | :turn

  @typedoc "File touch record."
  @type file_touch :: %{
          path: String.t(),
          action: :created | :modified | :deleted,
          timestamp: integer()
        }

  @typedoc "Context inherited by child subagent sessions."
  @type subagent_context :: SubagentContext.t()

  @typedoc "Active tool call tracked while the provider is executing tools."
  @type active_tool_call :: {tool_call_id :: String.t(), name :: String.t()}

  @typedoc "Remote attachment role."
  @type attachment_role :: :driver | :viewer

  @typedoc "Internal session state."
  @type state :: %{
          session_id: String.t(),
          remote_token: String.t() | nil,
          event_log_server: GenServer.server(),
          provider: pid() | nil,
          provider_module: module(),
          provider_opts: keyword(),
          status: status(),
          messages: [Message.t()],
          message_ids: [pos_integer()],
          next_message_id: pos_integer(),
          subscribers: MapSet.t(pid()),
          subscriber_roles: %{pid() => attachment_role()},
          driver: pid() | nil,
          total_usage: Event.token_usage(),
          error_message: String.t() | nil,
          pending_thinking_level: String.t() | nil,
          pending_approval: pending_approval() | nil,
          active_tool_calls: [active_tool_call()],
          active_tool_name: String.t() | nil,
          trust_levels: %{String.t() => trust_scope()},
          pending_auto_approvals: %{String.t() => trust_scope()},
          model_name: String.t(),
          provider_name: String.t(),
          notifier: module() | {module(), term()},
          background_subagent: boolean(),
          persist?: boolean(),
          hooks_enabled?: boolean(),
          session_start_hook_enabled?: boolean(),
          save_timer: reference() | nil,
          session_store_dir: String.t() | nil,
          created_at: DateTime.t(),
          last_message_at: DateTime.t(),
          branches: [Branch.t()],
          steering_queue: [String.t() | [ReqLLM.Message.ContentPart.t()]],
          follow_up_queue: [String.t() | [ReqLLM.Message.ContentPart.t()]],
          touched_files: %{String.t() => file_touch()},
          boundaries: %{String.t() => EditBoundary.t()},
          credentials_configured: boolean()
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
          :ok | {:queued, :steering} | {:error, term()}
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

  @doc "Seeds a session transcript without sending a prompt."
  @spec seed_messages(GenServer.server(), [Message.t()]) :: :ok
  def seed_messages(session, messages) when is_list(messages) do
    GenServer.call(session, {:seed_messages, messages})
  end

  @doc "Returns the current session status."
  @spec status(GenServer.server()) :: status()
  def status(session) do
    GenServer.call(session, :status)
  end

  @doc "Enters plan mode, where destructive tools are refused before execution."
  @spec enter_plan(GenServer.server()) :: :ok
  def enter_plan(session) do
    GenServer.call(session, :enter_plan)
  end

  @doc "Leaves plan mode and returns the session to execution mode."
  @spec enter_exec(GenServer.server()) :: :ok
  def enter_exec(session) do
    GenServer.call(session, :enter_exec)
  end

  @doc "Returns the provider context that should be inherited by a subagent."
  @spec subagent_context(GenServer.server()) :: subagent_context()
  def subagent_context(session) do
    GenServer.call(session, :subagent_context)
  end

  @doc "Returns the conversation messages."
  @spec messages(GenServer.server()) :: [Message.t()]
  def messages(session) do
    GenServer.call(session, :messages)
  end

  @doc "Returns the conversation messages paired with their stable BEAM-assigned IDs."
  @spec messages_with_ids(GenServer.server()) :: [{pos_integer(), Message.t()}]
  def messages_with_ids(session) do
    GenServer.call(session, :messages_with_ids)
  end

  @doc "Returns accumulated token usage."
  @spec usage(GenServer.server()) :: Event.token_usage()
  def usage(session) do
    GenServer.call(session, :usage)
  end

  @typedoc "Deprecated: use `MingaAgent.SessionMetadata.t()` directly."
  @type metadata :: SessionMetadata.t()

  @typedoc "Snapshot of session state needed by the editor for rendering."
  @type editor_snapshot :: %{
          status: status(),
          pending_approval: map() | nil,
          error: String.t() | nil,
          active_tool_name: String.t() | nil
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
  @type approval_decision :: :approve | :approve_session | :approve_turn | :reject

  @spec respond_to_approval(GenServer.server(), approval_decision()) ::
          :ok | {:error, :no_pending_approval}
  def respond_to_approval(session, decision)
      when decision in [:approve, :approve_session, :approve_turn, :reject] do
    GenServer.call(session, {:respond_to_approval, decision})
  end

  @doc "Trusts a tool for the session or current turn."
  @spec set_tool_trust(GenServer.server(), String.t(), trust_scope()) :: :ok
  def set_tool_trust(session, name, scope)
      when is_binary(name) and scope in [:session, :turn] do
    GenServer.call(session, {:set_tool_trust, name, scope})
  end

  @doc "Revokes trust for one tool, or all tools with `:all`."
  @spec revoke_tool_trust(GenServer.server(), String.t() | :all) :: :ok
  def revoke_tool_trust(session, name_or_all)
      when is_binary(name_or_all) or name_or_all == :all do
    GenServer.call(session, {:revoke_tool_trust, name_or_all})
  end

  @doc "Lists trusted tools and their trust scope."
  @spec list_tool_trust(GenServer.server()) :: %{String.t() => trust_scope()}
  def list_tool_trust(session) do
    GenServer.call(session, :list_tool_trust)
  end

  @doc "Returns the session ID."
  @spec session_id(GenServer.server()) :: String.t()
  def session_id(session) do
    GenServer.call(session, :session_id)
  end

  @doc """
  Loads a previously saved session, replacing the current conversation history.

  The current session is saved before replacement. The restored conversation history, branches, model, and metadata become the active session state.
  """
  @spec load_session(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def load_session(session, session_id) when is_binary(session_id) do
    GenServer.call(session, {:load_session, session_id})
  end

  @doc "Returns lightweight metadata about this session (for the picker)."
  @spec metadata(GenServer.server()) :: SessionMetadata.t()
  def metadata(session) do
    GenServer.call(session, :metadata)
  end

  @doc "Subscribes the calling process to session events."
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(session) do
    subscribe(session, self())
  end

  @doc "Subscribes the given process to session events."
  @spec subscribe(GenServer.server(), pid(), keyword()) :: :ok
  def subscribe(session, pid, opts \\ []) when is_pid(pid) do
    GenServer.call(session, {:subscribe, pid, opts})
  end

  @doc "Returns the current remote attachment role for a subscriber."
  @spec subscriber_role(GenServer.server(), pid()) :: attachment_role() | nil
  def subscriber_role(session, pid) when is_pid(pid) do
    GenServer.call(session, {:subscriber_role, pid})
  end

  @doc "Claims the driver role for a subscribed client when the role is vacant."
  @spec claim_driver(GenServer.server(), pid()) :: :ok | {:error, :driver_taken | :not_subscribed}
  def claim_driver(session, pid) when is_pid(pid) do
    GenServer.call(session, {:claim_driver, pid})
  end

  @doc "Sends a user prompt as an attached remote client."
  @spec send_prompt_as(GenServer.server(), pid(), String.t() | [ReqLLM.Message.ContentPart.t()]) ::
          :ok | {:queued, :steering} | {:error, term()}
  def send_prompt_as(session, client_pid, content)
      when is_pid(client_pid) and (is_binary(content) or is_list(content)) do
    GenServer.call(session, {:send_prompt_as, client_pid, content})
  end

  @doc "Responds to a pending tool approval as an attached remote client."
  @spec respond_to_approval_as(GenServer.server(), pid(), approval_decision()) ::
          :ok | {:error, :no_pending_approval | :not_driver}
  def respond_to_approval_as(session, client_pid, decision)
      when is_pid(client_pid) and decision in [:approve, :approve_session, :approve_turn, :reject] do
    respond_to_approval_as(session, client_pid, nil, decision)
  end

  @doc "Responds to a pending tool approval by stable approval id as an attached driver."
  @spec respond_to_approval_as(GenServer.server(), pid(), String.t() | nil, approval_decision()) ::
          :ok | {:error, :approval_not_found | :no_pending_approval | :not_driver}
  def respond_to_approval_as(session, client_pid, approval_id, decision)
      when is_pid(client_pid) and (is_binary(approval_id) or is_nil(approval_id)) and
             decision in [:approve, :approve_session, :approve_turn, :reject] do
    GenServer.call(session, {:respond_to_approval_as, client_pid, approval_id, decision})
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

  @doc """
  Re-checks whether any provider credential is now configured.

  Call after `/auth` or `/login` so the current session stops gating prompts
  and the UI's "not configured" state clears without a restart.
  """
  @spec refresh_credentials(GenServer.server()) :: :ok
  def refresh_credentials(session) do
    GenServer.cast(session, :refresh_credentials)
  end

  @doc """
  Queues a message as a steering prompt (injected between tool calls on the next turn).

  When the agent is idle, behaves identically to `send_prompt/2`.
  Returns `{:queued, :steering}` when the message was queued.
  """
  @spec queue_steering(GenServer.server(), String.t() | [ReqLLM.Message.ContentPart.t()]) ::
          :ok | {:queued, :steering} | {:error, term()}
  def queue_steering(session, content) when is_binary(content) or is_list(content) do
    GenServer.call(session, {:send_prompt, content})
  end

  @doc """
  Queues a message as a follow-up (sent automatically once the current agent run finishes).

  When the agent is idle, behaves identically to `send_prompt/2`.
  Returns `{:queued, :follow_up}` when the message was queued.
  """
  @spec queue_follow_up(GenServer.server(), String.t() | [ReqLLM.Message.ContentPart.t()]) ::
          :ok | {:queued, :follow_up} | {:error, term()}
  def queue_follow_up(session, content) when is_binary(content) or is_list(content) do
    GenServer.call(session, {:send_follow_up, content})
  end

  @doc "Pops and returns all pending steering messages, clearing the steering queue."
  @spec dequeue_steering(GenServer.server()) ::
          [String.t() | [ReqLLM.Message.ContentPart.t()]]
  def dequeue_steering(session) do
    GenServer.call(session, :dequeue_steering)
  end

  @doc """
  Returns files touched by this agent session, ordered by most recent first.

  Each entry contains:
  - `path`: relative file path
  - `action`: `:created`, `:modified`, or `:deleted`
  - `timestamp`: monotonic timestamp of the last touch

  Derived from tool call history (file_write, file_edit, multi_edit_file, apply_diff).
  """
  @spec touched_files(GenServer.server()) :: [file_touch()]
  def touched_files(session) do
    GenServer.call(session, :touched_files)
  end

  @doc """
  Sets an edit boundary for the agent on the given file path.

  The agent will be restricted to editing within the specified line range
  (0-indexed, both inclusive). Edits outside the boundary are rejected with
  a descriptive error message.
  """
  @spec set_boundary(GenServer.server(), String.t(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, String.t()}
  def set_boundary(session, path, start_line, end_line)
      when is_binary(path) and is_integer(start_line) and is_integer(end_line) do
    GenServer.call(session, {:set_boundary, path, start_line, end_line})
  end

  @doc "Clears the edit boundary for the given file path, restoring full-buffer access."
  @spec clear_boundary(GenServer.server(), String.t()) :: :ok
  def clear_boundary(session, path) when is_binary(path) do
    GenServer.call(session, {:clear_boundary, path})
  end

  @doc "Clears all edit boundaries for this session."
  @spec clear_all_boundaries(GenServer.server()) :: :ok
  def clear_all_boundaries(session) do
    GenServer.call(session, :clear_all_boundaries)
  end

  @doc "Returns the edit boundary for the given file path, or nil if unbounded."
  @spec boundary_for(GenServer.server(), String.t()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def boundary_for(session, path) when is_binary(path) do
    GenServer.call(session, {:boundary_for, path})
  end

  @doc """
  Returns both queues and clears them. Used by abort (Ctrl-C) and dequeue (Alt+Up)
  so pending messages can be restored to the prompt input.
  """
  @spec recall_queues(GenServer.server()) ::
          {[String.t() | [ReqLLM.Message.ContentPart.t()]],
           [String.t() | [ReqLLM.Message.ContentPart.t()]]}
  def recall_queues(session) do
    GenServer.call(session, :recall_queues)
  end

  @doc "Clears both queues without returning their contents."
  @spec clear_queues(GenServer.server()) :: :ok
  def clear_queues(session) do
    GenServer.call(session, :clear_queues)
  end

  @doc "Returns both queues without modifying them (for pending message display)."
  @spec get_queued_messages(GenServer.server()) ::
          {[String.t() | [ReqLLM.Message.ContentPart.t()]],
           [String.t() | [ReqLLM.Message.ContentPart.t()]]}
  def get_queued_messages(session) do
    GenServer.call(session, :get_queued_messages)
  end

  @doc """
  Converts a list of queue entries (strings or ContentPart lists) into a single
  string suitable for display or restoring to the prompt input.
  """
  @spec combine_queue_entries_to_text([String.t() | [ReqLLM.Message.ContentPart.t()]]) ::
          String.t()
  def combine_queue_entries_to_text(entries) do
    entries
    |> Enum.map(fn
      text when is_binary(text) ->
        text

      parts when is_list(parts) ->
        parts
        |> Enum.filter(&(&1.type == :text))
        |> Enum.map_join("", & &1.text)
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc "Returns the provider pid for direct provider-specific calls."
  @spec get_provider(GenServer.server()) :: pid() | nil
  def get_provider(session) do
    GenServer.call(session, :get_provider)
  end

  @doc "Returns whether this session persists its conversation to disk."
  @spec persist?(GenServer.server()) :: boolean()
  def persist?(session) do
    GenServer.call(session, :persist?)
  end

  @doc "Returns whether hooks are enabled for this session."
  @spec hooks_enabled?(GenServer.server()) :: boolean()
  def hooks_enabled?(session) do
    GenServer.call(session, :hooks_enabled?)
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

    now = DateTime.utc_now()

    state = %{
      session_id: session_id,
      remote_token: Keyword.get(opts, :remote_token),
      event_log_server: Keyword.get(opts, :event_log_server, EventLog),
      provider: nil,
      provider_module: provider_module,
      provider_opts: provider_opts,
      status: :idle,
      messages: [
        Message.system(initial_system_message(timestamp, Keyword.get(opts, :startup_notice)))
      ],
      message_ids: [1],
      next_message_id: 2,
      subscribers: MapSet.new(),
      subscriber_roles: %{},
      driver: nil,
      total_usage: TurnUsage.new(),
      error_message: nil,
      pending_thinking_level: initial_thinking_level,
      pending_approval: nil,
      active_tool_calls: [],
      active_tool_name: nil,
      trust_levels: %{},
      pending_auto_approvals: %{},
      model_name: model_name,
      provider_name: provider_name,
      notifier: Keyword.get(opts, :notifier, Notifier),
      background_subagent: Keyword.get(opts, :background_subagent, false),
      persist?: Keyword.get(opts, :persist?, true),
      hooks_enabled?: Keyword.get(opts, :hooks_enabled?, true),
      session_start_hook_enabled?:
        Keyword.get(opts, :session_start_hook_enabled?, Keyword.get(opts, :hooks_enabled?, true)),
      save_timer: nil,
      session_store_dir: Keyword.get(opts, :session_store_dir),
      created_at: now,
      last_message_at: now,
      branches: [],
      steering_queue: [],
      follow_up_queue: [],
      touched_files: %{},
      boundaries: %{},
      # Whether any usable provider credential exists. Computed once when the
      # provider starts (the Ollama probe can block briefly) and refreshed when
      # the user runs /auth or /login. Gates send_prompt and drives the UI's
      # "not configured" state so we never advertise a model we can't call.
      credentials_configured: true
    }

    mark_interrupted_work(state)

    EventLog.record(
      state.session_id,
      :session_started,
      %{
        model: state.model_name,
        provider: state.provider_name,
        background_subagent: state.background_subagent
      },
      state.event_log_server
    )

    # Start provider asynchronously so init doesn't block
    send(self(), :start_provider)

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:seed_messages, messages}, _from, state) do
    state =
      state
      |> append_msgs(messages)
      |> seed_provider_messages(messages)
      |> notify_messages_changed()

    {:reply, :ok, state}
  end

  def handle_call({:send_prompt_as, client_pid, content}, _from, state) do
    case driver_allowed?(state, client_pid) do
      true -> handle_send_prompt(content, state)
      false -> {:reply, {:error, :not_driver}, state}
    end
  end

  def handle_call({:send_prompt, content}, _from, state) do
    handle_send_prompt(content, state)
  end

  def handle_call({:send_follow_up, _content}, _from, %{provider: nil} = state) do
    {:reply, {:error, :provider_not_ready}, state}
  end

  def handle_call({:send_follow_up, content}, _from, %{status: status} = state)
      when status in [:thinking, :tool_executing] do
    # Agent is busy: queue as a follow-up that sends automatically once the current run finishes.
    state = %{state | follow_up_queue: state.follow_up_queue ++ [content]}
    broadcast(state, {:prompt_queued, content, :follow_up})
    {:reply, {:queued, :follow_up}, state}
  end

  def handle_call({:send_follow_up, content}, _from, state) do
    # Agent is idle: treat follow-up as a regular prompt.
    {user_msg, send_content} = build_user_message(content)
    state = append_msg(state, user_msg)
    record_user_message(state, user_msg)
    state = notify_messages_changed(state)

    case state.provider_module.send_prompt(state.provider, send_content) do
      :ok -> {:reply, :ok, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call(:dequeue_steering, _from, state) do
    steering = state.steering_queue

    if steering == [] do
      {:reply, [], state}
    else
      # Add each steering message to conversation history so it appears in chat.
      new_msgs =
        Enum.map(steering, fn content ->
          {user_msg, _} = build_user_message(content)
          user_msg
        end)

      state = %{state | steering_queue: []}
      Enum.each(new_msgs, &record_user_message(state, &1))
      state = append_msgs(state, new_msgs)
      state = notify_messages_changed(state)
      {:reply, steering, state}
    end
  end

  def handle_call(:recall_queues, _from, state) do
    result = {state.steering_queue, state.follow_up_queue}
    state = %{state | steering_queue: [], follow_up_queue: []}
    broadcast(state, :queues_recalled)
    {:reply, result, state}
  end

  def handle_call(:clear_queues, _from, state) do
    state = %{state | steering_queue: [], follow_up_queue: []}
    broadcast(state, :queues_recalled)
    {:reply, :ok, state}
  end

  def handle_call(:get_queued_messages, _from, state) do
    {:reply, {state.steering_queue, state.follow_up_queue}, state}
  end

  def handle_call(:touched_files, _from, state) do
    files =
      state.touched_files
      |> Map.values()
      |> Enum.sort_by(& &1.timestamp, :desc)

    {:reply, files, state}
  end

  def handle_call({:set_boundary, path, start_line, end_line}, _from, state) do
    abs_path = Path.expand(path)

    case EditBoundary.new(start_line, end_line) do
      {:ok, boundary} ->
        {:reply, :ok, %{state | boundaries: Map.put(state.boundaries, abs_path, boundary)}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:clear_boundary, path}, _from, state) do
    abs_path = Path.expand(path)
    {:reply, :ok, %{state | boundaries: Map.delete(state.boundaries, abs_path)}}
  end

  def handle_call(:clear_all_boundaries, _from, state) do
    {:reply, :ok, %{state | boundaries: %{}}}
  end

  def handle_call({:boundary_for, path}, _from, state) do
    abs_path = Path.expand(path)

    result =
      case Map.get(state.boundaries, abs_path) do
        nil -> nil
        %EditBoundary{start_line: s, end_line: e} -> {s, e}
      end

    {:reply, result, state}
  end

  def handle_call(:abort, _from, %{provider: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:abort, _from, state) do
    state.provider_module.abort(state.provider)

    # Mark any running tool calls as aborted
    messages =
      Enum.map(state.messages, fn
        {:tool_call, %ToolCall{} = tc} -> {:tool_call, ToolCall.abort(tc)}
        other -> other
      end)

    # Append "Aborted" system message, clear any pending approval
    state = %{state | messages: messages, pending_approval: nil}
    state = append_system_message(state, "Aborted", :info)
    state = notify_messages_changed(state)
    state = set_idle_or_plan(state)
    {:reply, :ok, state}
  end

  def handle_call(:new_session, _from, state) do
    if state.provider do
      state.provider_module.new_session(state.provider)
    end

    now = DateTime.utc_now()
    timestamp = Calendar.strftime(now, "%H:%M:%S UTC")

    state = cancel_save_timer(state)

    state = %{
      state
      | session_id: generate_session_id(),
        status: :idle,
        total_usage: TurnUsage.new(),
        error_message: nil,
        pending_approval: nil,
        active_tool_calls: [],
        active_tool_name: nil,
        created_at: now,
        last_message_at: now,
        steering_queue: [],
        follow_up_queue: [],
        touched_files: %{},
        boundaries: %{},
        trust_levels: %{},
        pending_auto_approvals: %{}
    }

    state = reset_messages(state, [Message.system("Session cleared · #{timestamp}")])

    broadcast(state, {:status_changed, :idle})
    state = notify_messages_changed(state)
    {:reply, :ok, state}
  end

  def handle_call(:session_id, _from, state) do
    {:reply, state.session_id, state}
  end

  def handle_call(:enter_plan, _from, state) do
    reject_pending_approval(state.pending_approval)
    state = %{state | pending_approval: nil}
    state = append_system_message(state, plan_mode_message(), :info)
    state = notify_messages_changed(state)
    state = set_status(state, :plan)
    {:reply, :ok, state}
  end

  def handle_call(:enter_exec, _from, %{status: :plan} = state) do
    state = append_system_message(state, exec_mode_message(), :info)
    state = notify_messages_changed(state)
    state = set_status(state, :idle)
    {:reply, :ok, state}
  end

  def handle_call(:enter_exec, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call({:load_session, session_id}, _from, state) do
    case SessionStore.load(session_id, state.session_store_dir) do
      {:ok, data} ->
        case restore_loaded_session(state, data) do
          {:ok, state} -> {:reply, :ok, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call(:subagent_context, _from, state) do
    {:reply, build_subagent_context(state), state}
  end

  def handle_call(:messages, _from, state) do
    {:reply, state.messages, state}
  end

  def handle_call(:messages_with_ids, _from, state) do
    paired = Enum.zip(state.message_ids, state.messages)
    {:reply, paired, state}
  end

  def handle_call(:usage, _from, state) do
    {:reply, state.total_usage, state}
  end

  def handle_call(:get_provider, _from, state) do
    {:reply, state.provider, state}
  end

  def handle_call(:persist?, _from, state) do
    {:reply, state.persist?, state}
  end

  def handle_call(:hooks_enabled?, _from, state) do
    {:reply, state.hooks_enabled?, state}
  end

  def handle_call(:editor_snapshot, _from, state) do
    snapshot = %{
      status: state.status,
      pending_approval: public_pending_approval(state.pending_approval),
      error: state.error_message,
      active_tool_name: state.active_tool_name
    }

    {:reply, snapshot, state}
  end

  def handle_call(:metadata, _from, state) do
    first_prompt = first_user_prompt(state.messages)

    meta = %SessionMetadata{
      id: state.session_id,
      title: readable_title(first_prompt),
      model_name: state.model_name,
      provider_name: state.provider_name,
      created_at: state.created_at,
      last_message_at: state.last_message_at,
      message_count: length(state.messages),
      turn_count: count_user_turns(state.messages),
      first_prompt: first_prompt,
      cost: state.total_usage.cost,
      status: state.status
    }

    {:reply, meta, state}
  end

  def handle_call({:respond_to_approval_as, client_pid, approval_id, decision}, _from, state) do
    case driver_allowed?(state, client_pid) do
      true -> handle_approval_response(approval_id, decision, state)
      false -> {:reply, {:error, :not_driver}, state}
    end
  end

  def handle_call({:respond_to_approval, decision}, _from, state) do
    handle_approval_response(decision, state)
  end

  def handle_call({:set_tool_trust, name, scope}, _from, state) do
    {:reply, :ok, put_tool_trust(state, name, scope)}
  end

  def handle_call({:revoke_tool_trust, :all}, _from, state) do
    {:reply, :ok, %{state | trust_levels: %{}}}
  end

  def handle_call({:revoke_tool_trust, name}, _from, state) do
    {:reply, :ok, %{state | trust_levels: Map.delete(state.trust_levels, name)}}
  end

  def handle_call(:list_tool_trust, _from, state) do
    {:reply, state.trust_levels, state}
  end

  def handle_call({:subscribe, pid, opts}, _from, state) do
    Process.monitor(pid)
    role = Keyword.get(opts, :role, default_subscriber_role(state))
    state = put_subscriber(state, pid, role)
    {:reply, :ok, state}
  end

  def handle_call({:subscriber_role, pid}, _from, state) do
    {:reply, Map.get(state.subscriber_roles, pid), state}
  end

  def handle_call({:claim_driver, pid}, _from, state) do
    case claim_driver_role(state, pid) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, remove_subscriber(state, pid)}
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
        {:tool_call, %ToolCall{} = tc} -> {:tool_call, ToolCall.toggle_collapsed(tc)}
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
        {:tool_call, %ToolCall{collapsed: true}} -> true
        {:thinking, _, true} -> true
        _ -> false
      end)

    target = !any_collapsed

    messages =
      Enum.map(state.messages, fn
        {:tool_call, %ToolCall{} = tc} -> {:tool_call, ToolCall.set_collapsed(tc, target)}
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
        truncated_ids = Enum.take(state.message_ids, length(truncated))
        state = %{state | messages: truncated, message_ids: truncated_ids, branches: branches}
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
        state = reset_messages(state, branch.messages)
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

  def handle_cast(:refresh_credentials, state) do
    {:noreply, refresh_credentials_state(state)}
  end

  @impl GenServer
  def handle_info(:start_provider, state) do
    case start_provider(state) do
      {:ok, pid} ->
        Process.monitor(pid)
        state = %{state | provider: pid}
        state = seed_provider_messages(state, state.messages)
        state = apply_pending_thinking_level(state)
        state = refresh_credentials_state(state)
        state = maybe_show_auth_onboarding(state)
        dispatch_session_start(state)
        {:noreply, state}

      {:error, reason} ->
        Minga.Log.error(:agent, "[Agent.Session] failed to start provider: #{inspect(reason)}")
        state = %{state | error_message: format_error(reason)}
        state = set_error_status(state)
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
    state = %{state | provider: nil, error_message: "Agent provider crashed"}
    state = set_error_status(state)
    broadcast(state, {:error, state.error_message})

    # Try to restart the provider after a brief delay
    Process.send_after(self(), :start_provider, 2000)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # A subscriber died, remove it and vacate the driver role if needed.
    {:noreply, remove_subscriber(state, pid)}
  end

  def handle_info(:save_session, state) do
    state = %{state | save_timer: nil}
    save_to_disk(state)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @spec handle_approval_response(approval_decision(), state()) ::
          {:reply, :ok | {:error, :no_pending_approval}, state()}
  defp handle_approval_response(decision, state),
    do: handle_approval_response(nil, decision, state)

  @spec handle_approval_response(String.t() | nil, approval_decision(), state()) ::
          {:reply, :ok | {:error, :approval_not_found | :no_pending_approval}, state()}
  defp handle_approval_response(_approval_id, _decision, %{pending_approval: nil} = state) do
    Minga.Log.warning(:agent, "[Session] respond_to_approval called with no pending approval")
    {:reply, {:error, :no_pending_approval}, state}
  end

  defp handle_approval_response(approval_id, _decision, %{pending_approval: approval} = state)
       when is_binary(approval_id) and approval.tool_call_id != approval_id do
    {:reply, {:error, :approval_not_found}, state}
  end

  defp handle_approval_response(_approval_id, decision, state) do
    %{tool_call_id: tool_call_id, reply_to: reply_to} = approval = state.pending_approval
    state = maybe_set_trust_for_decision(state, approval.name, decision)

    # Send the execution decision directly to the blocked Task process.
    send(reply_to, {:tool_approval_response, tool_call_id, execution_decision(decision)})

    EventLog.record(
      state.session_id,
      :approval_resolved,
      %{
        approval_id: tool_call_id,
        tool_call_id: tool_call_id,
        name: approval.name,
        decision: decision
      },
      state.event_log_server
    )

    state = maybe_record_rejection(state, approval, decision)
    state = %{state | pending_approval: nil}
    state = notify_messages_changed(state)
    broadcast(state, {:approval_resolved, decision})
    {:reply, :ok, state}
  end

  @spec handle_send_prompt(String.t() | [ReqLLM.Message.ContentPart.t()], state()) ::
          {:reply, :ok | {:queued, :steering} | {:error, term()}, state()}
  defp handle_send_prompt(_text, %{provider: nil} = state) do
    {:reply, {:error, :provider_not_ready}, state}
  end

  defp handle_send_prompt(content, %{status: status} = state)
       when status in [:thinking, :tool_executing] do
    # Agent is busy: queue the message as a steering prompt. It will be injected
    # into the agent's context between tool calls.
    state = %{state | steering_queue: state.steering_queue ++ [content]}
    broadcast(state, {:prompt_queued, content, :steering})
    {:reply, {:queued, :steering}, state}
  end

  defp handle_send_prompt(content, %{credentials_configured: false} = state) do
    # No usable provider yet. Show the user's message followed by a gentle
    # setup nudge instead of attempting a call that would fail with a raw
    # provider error. Reply :ok so the input clears like a normal submit.
    {user_msg, _send_content} = build_user_message(content)

    state = append_msg(state, user_msg)
    record_user_message(state, user_msg)

    state =
      state
      |> append_system_message(auth_required_message(), :info)
      |> notify_messages_changed()

    {:reply, :ok, state}
  end

  defp handle_send_prompt(content, state) do
    case dispatch_user_prompt_submit(state, content) do
      :ok ->
        {user_msg, send_content} = build_user_message(content)
        state = append_msg(state, user_msg)
        record_user_message(state, user_msg)
        state = notify_messages_changed(state)

        case state.provider_module.send_prompt(state.provider, send_content) do
          :ok ->
            {:reply, :ok, state}

          {:error, _} = err ->
            {:reply, err, state}
        end

      {:error, %HookResult{} = result} ->
        {:reply, {:error, {:hook_veto, HookResult.message(result)}}, state}
    end
  end

  # ── Event handling ──────────────────────────────────────────────────────────

  @spec handle_provider_event(Event.t(), state()) :: state()
  defp handle_provider_event(%Event.AgentStart{}, state) do
    state = %{state | pending_approval: nil}
    set_working_status(state, :thinking)
  end

  defp handle_provider_event(%Event.AgentEnd{usage: usage}, state) do
    notify(state, :complete, completion_notification(state))

    state =
      if usage do
        log_turn_usage(usage, state)

        state = %{state | total_usage: TurnUsage.add(state.total_usage, usage)}

        state = append_msg(state, Message.usage(usage))
        notify_messages_changed(state)
      else
        state
      end

    dispatch_stop(state)
    state = clear_turn_trust(state)

    # Collect pending messages from both queues. Steering messages that arrived
    # after the last tool call (or just before AgentEnd) would otherwise be
    # orphaned because dequeue_steering is only called between tool calls during
    # an active agent loop. Merge them with follow-ups so nothing gets lost.
    all_pending = state.steering_queue ++ state.follow_up_queue

    case all_pending do
      [] ->
        set_idle_or_plan(state)

      pending ->
        # Auto-send queued messages as a new turn. Combine all pending
        # messages into a single prompt so they arrive as one user message.
        combined = combine_queue_entries_to_text(pending)
        {user_msg, send_content} = build_user_message(combined)

        state = %{state | steering_queue: [], follow_up_queue: []}
        state = append_msg(state, user_msg)
        record_user_message(state, user_msg)
        state = notify_messages_changed(state)

        case state.provider_module.send_prompt(state.provider, send_content) do
          :ok ->
            # AgentStart event from the provider will transition us to :thinking.
            state

          {:error, _reason} ->
            set_idle_or_plan(state)
        end
    end
  end

  defp handle_provider_event(%Event.TextDelta{delta: delta}, state) do
    # Auto-collapse any expanded thinking blocks (thinking is done)
    messages = collapse_thinking_blocks(state.messages)

    state =
      case append_to_last_assistant(messages, delta) do
        {:updated, updated_messages} ->
          %{state | messages: updated_messages}

        {:appended, new_msg} ->
          %{state | messages: messages} |> append_msg(new_msg)
      end

    broadcast(state, {:text_delta, delta})
    state
  end

  defp handle_provider_event(%Event.ThinkingDelta{delta: delta}, state) do
    state =
      case append_to_last_thinking(state.messages, delta) do
        {:updated, updated_messages} ->
          %{state | messages: updated_messages}

        {:appended, new_msg} ->
          append_msg(state, new_msg)
      end

    broadcast(state, {:thinking_delta, delta})
    state
  end

  defp handle_provider_event(%Event.ToolStart{} = event, state) do
    {scope, pending_auto_approvals} = Map.pop(state.pending_auto_approvals, event.tool_call_id)

    msg =
      event.tool_call_id
      |> ToolCall.new(event.name, event.args)
      |> ToolCall.set_auto_approved_scope(scope)
      |> then(&{:tool_call, &1})

    state = %{state | pending_auto_approvals: pending_auto_approvals}
    state = append_msg(state, msg)
    state = track_active_tool_start(state, event.tool_call_id, event.name)
    state = set_working_status(state, :tool_executing)

    EventLog.record(
      state.session_id,
      :tool_call_started,
      %{tool_call_id: event.tool_call_id, name: event.name, args: event.args},
      state.event_log_server
    )

    broadcast(state, {:tool_started, event.name, event.args})
    notify_messages_changed(state)
  end

  defp handle_provider_event(%Event.ToolFileChanged{} = event, state) do
    tool_name = tool_name_for_call(state.active_tool_calls, event.tool_call_id)

    broadcast(
      state,
      {:file_changed, event.path, event.before_content, event.after_content, event.tool_call_id,
       tool_name}
    )

    state = record_file_touch(state, event.path, event.before_content, event.after_content)
    state
  end

  defp handle_provider_event(%Event.SystemMessage{} = event, state) do
    state = append_system_message(state, event.message, event.level)
    notify_messages_changed(state)
  end

  defp handle_provider_event(%Event.ToolApproval{} = event, state) do
    case Map.get(state.trust_levels, event.name) do
      nil ->
        request_tool_approval(event, state)

      scope ->
        auto_approve_tool(event, state, scope)
    end
  end

  defp handle_provider_event(%Event.ToolUpdate{} = event, state) do
    messages =
      update_tool_call(state.messages, event.tool_call_id, fn tc ->
        ToolCall.update_partial(tc, event.partial_result)
      end)

    state = %{state | messages: messages}
    broadcast(state, {:tool_update, event.tool_call_id, event.name, event.partial_result})
    state
  end

  defp handle_provider_event(%Event.ToolEnd{} = event, state) do
    messages =
      update_tool_call(state.messages, event.tool_call_id, fn tc ->
        if event.is_error do
          ToolCall.error(tc, event.result)
        else
          ToolCall.complete(tc, event.result)
        end
      end)

    state = %{
      state
      | messages: messages,
        pending_auto_approvals: Map.delete(state.pending_auto_approvals, event.tool_call_id)
    }

    state = track_active_tool_end(state, event.tool_call_id)
    status = if event.is_error, do: :error, else: :done

    EventLog.record(
      state.session_id,
      :tool_call_finished,
      %{tool_call_id: event.tool_call_id, name: event.name, result: event.result, status: status},
      state.event_log_server
    )

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
    # Show one human-readable line in the transcript. The raw error is already
    # logged to the Messages panel by the provider, so we don't repeat it here.
    friendly = humanize_error(message)
    notify(state, :error, friendly)
    state = set_error_status(state)
    state = %{state | error_message: friendly}
    state = append_system_message(state, friendly, :error)
    broadcast(state, {:error, friendly})
    state
  end

  @spec request_tool_approval(Event.ToolApproval.t(), state()) :: state()
  defp request_tool_approval(event, state) do
    notify(state, :approval, "Approval needed: #{event.name}")

    approval =
      MingaAgent.ToolApproval.new(
        tool_call_id: event.tool_call_id,
        name: event.name,
        args: event.args,
        reply_to: event.reply_to
      )

    state = %{state | pending_approval: approval}
    broadcast(state, {:approval_pending, MingaAgent.ToolApproval.public(approval)})
    state
  end

  @spec auto_approve_tool(Event.ToolApproval.t(), state(), trust_scope()) :: state()
  defp auto_approve_tool(event, state, scope) do
    send(event.reply_to, {:tool_approval_response, event.tool_call_id, :approve})

    pending_auto_approvals = Map.put(state.pending_auto_approvals, event.tool_call_id, scope)

    messages =
      update_tool_call(state.messages, event.tool_call_id, fn tc ->
        ToolCall.set_auto_approved_scope(tc, scope)
      end)

    state = %{state | messages: messages, pending_auto_approvals: pending_auto_approvals}
    broadcast(state, {:tool_auto_approved, event.tool_call_id, event.name, scope})
    notify_messages_changed(state)
  end

  @spec completion_notification(state()) :: String.t()
  defp completion_notification(%{background_subagent: true, session_id: session_id}) do
    "Sub-agent #{session_id} finished"
  end

  defp completion_notification(_state), do: "Agent finished"

  @spec notify(state(), atom(), String.t()) :: :ok
  defp notify(%{notifier: {module, arg}} = state, trigger, message) when is_atom(module) do
    dispatch_notification(state, trigger, message)
    module.notify(trigger, message, arg)
  end

  defp notify(%{notifier: module} = state, trigger, message) when is_atom(module) do
    dispatch_notification(state, trigger, message)
    module.notify(trigger, message)
  end

  # ── Message list helpers ────────────────────────────────────────────────────

  # Appends a message and assigns it a new stable ID.
  @spec append_msg(state(), Message.t()) :: state()
  defp append_msg(state, msg) do
    id = state.next_message_id

    %{
      state
      | messages: state.messages ++ [msg],
        message_ids: state.message_ids ++ [id],
        next_message_id: id + 1
    }
  end

  # Appends multiple messages, assigning each a new stable ID.
  @spec append_msgs(state(), [Message.t()]) :: state()
  defp append_msgs(state, []), do: state

  defp append_msgs(state, msgs) do
    count = length(msgs)
    base_id = state.next_message_id
    new_ids = Enum.to_list(base_id..(base_id + count - 1))

    %{
      state
      | messages: state.messages ++ msgs,
        message_ids: state.message_ids ++ new_ids,
        next_message_id: base_id + count
    }
  end

  # Replaces all messages and resets IDs (used by new_session, load_session, switch_branch).
  @spec reset_messages(state(), [Message.t()]) :: state()
  defp reset_messages(state, msgs) do
    count = length(msgs)
    ids = Enum.to_list(1..max(count, 1))

    %{
      state
      | messages: msgs,
        message_ids: Enum.take(ids, count),
        next_message_id: count + 1
    }
  end

  @spec append_system_message(state(), String.t(), Message.system_level()) :: state()
  defp append_system_message(state, text, level) do
    msg = Message.system(text, level)
    append_msg(state, msg)
  end

  @spec maybe_set_trust_for_decision(state(), String.t(), approval_decision()) :: state()
  defp maybe_set_trust_for_decision(state, name, :approve_session),
    do: put_tool_trust(state, name, :session)

  defp maybe_set_trust_for_decision(state, name, :approve_turn),
    do: put_tool_trust(state, name, :turn)

  defp maybe_set_trust_for_decision(state, _name, _decision), do: state

  @spec put_tool_trust(state(), String.t(), trust_scope()) :: state()
  defp put_tool_trust(state, name, scope) when is_binary(name) and scope in [:session, :turn] do
    %{state | trust_levels: Map.put(state.trust_levels, name, scope)}
  end

  @spec execution_decision(approval_decision()) :: :approve | :reject
  defp execution_decision(:reject), do: :reject
  defp execution_decision(_decision), do: :approve

  @spec maybe_record_rejection(state(), MingaAgent.ToolApproval.t(), atom()) :: state()
  defp maybe_record_rejection(state, approval, :reject) do
    append_system_message(
      state,
      "Denied #{approval.name}: the tool was refused and the agent was notified.",
      :info
    )
  end

  defp maybe_record_rejection(state, _approval, _decision), do: state

  @spec public_pending_approval(MingaAgent.ToolApproval.t() | nil) :: map() | nil
  defp public_pending_approval(nil), do: nil

  defp public_pending_approval(%MingaAgent.ToolApproval{} = approval),
    do: MingaAgent.ToolApproval.public(approval)

  @spec append_to_last_assistant([Message.t()], String.t()) ::
          {:updated, [Message.t()]} | {:appended, Message.t()}
  defp append_to_last_assistant(messages, delta) do
    case List.last(messages) do
      {:assistant, text} ->
        {:updated, List.replace_at(messages, length(messages) - 1, {:assistant, text <> delta})}

      _ ->
        {:appended, Message.assistant(delta)}
    end
  end

  @spec collapse_thinking_blocks([Message.t()]) :: [Message.t()]
  defp collapse_thinking_blocks(messages) do
    Enum.map(messages, fn
      {:thinking, text, false} -> {:thinking, text, true}
      other -> other
    end)
  end

  @spec append_to_last_thinking([Message.t()], String.t()) ::
          {:updated, [Message.t()]} | {:appended, Message.t()}
  defp append_to_last_thinking(messages, delta) do
    case List.last(messages) do
      {:thinking, text, _collapsed} ->
        {:updated,
         List.replace_at(messages, length(messages) - 1, {:thinking, text <> delta, false})}

      _ ->
        {:appended, Message.thinking(delta)}
    end
  end

  @spec update_tool_call([Message.t()], String.t(), (ToolCall.t() -> ToolCall.t())) ::
          [Message.t()]
  defp update_tool_call(messages, tool_call_id, updater) do
    Enum.map(messages, fn
      {:tool_call, %ToolCall{id: ^tool_call_id} = tc} -> {:tool_call, updater.(tc)}
      other -> other
    end)
  end

  # ── Status management ──────────────────────────────────────────────────────

  @spec reject_pending_approval(pending_approval() | nil) :: :ok
  defp reject_pending_approval(nil), do: :ok

  defp reject_pending_approval(%{tool_call_id: tool_call_id, reply_to: reply_to}) do
    send(reply_to, {:tool_approval_response, tool_call_id, :reject})
    :ok
  end

  @spec set_status(state(), status()) :: state()
  defp set_status(state, new_status) do
    state = %{state | status: new_status}

    state =
      if new_status == :tool_executing do
        state
      else
        clear_active_tool_tracking(state)
      end

    state = clear_turn_trust_for_status(state, new_status)
    broadcast(state, {:status_changed, new_status})
    state
  end

  @spec clear_turn_trust_for_status(state(), status()) :: state()
  defp clear_turn_trust_for_status(state, status) when status in [:idle, :error] do
    clear_turn_trust(state)
  end

  defp clear_turn_trust_for_status(state, _status), do: state

  @spec clear_turn_trust(state()) :: state()
  defp clear_turn_trust(state) do
    %{state | trust_levels: drop_turn_trust(state.trust_levels), pending_auto_approvals: %{}}
  end

  @spec drop_turn_trust(%{String.t() => trust_scope()}) :: %{String.t() => trust_scope()}
  defp drop_turn_trust(trust_levels) do
    Map.reject(trust_levels, fn {_name, scope} -> scope == :turn end)
  end

  @spec set_working_status(state(), :thinking | :tool_executing) :: state()
  defp set_working_status(%{status: :plan} = state, _new_status), do: state
  defp set_working_status(state, new_status), do: set_status(state, new_status)

  @spec set_idle_or_plan(state()) :: state()
  defp set_idle_or_plan(%{status: :plan} = state), do: state
  defp set_idle_or_plan(state), do: set_status(state, :idle)

  @spec set_error_status(state()) :: state()
  defp set_error_status(%{status: :plan} = state), do: state
  defp set_error_status(state), do: set_status(state, :error)

  @spec track_active_tool_start(state(), String.t(), String.t()) :: state()
  defp track_active_tool_start(state, tool_call_id, name) do
    active_tool_calls = state.active_tool_calls ++ [{tool_call_id, name}]

    %{
      state
      | active_tool_calls: active_tool_calls,
        active_tool_name: current_active_tool_name(active_tool_calls)
    }
  end

  @spec track_active_tool_end(state(), String.t()) :: state()
  defp track_active_tool_end(state, tool_call_id) do
    active_tool_calls =
      Enum.reject(state.active_tool_calls, fn {id, _name} -> id == tool_call_id end)

    %{
      state
      | active_tool_calls: active_tool_calls,
        active_tool_name: current_active_tool_name(active_tool_calls)
    }
  end

  @spec clear_active_tool_tracking(state()) :: state()
  defp clear_active_tool_tracking(state) do
    %{state | active_tool_calls: [], active_tool_name: nil}
  end

  @spec current_active_tool_name([active_tool_call()]) :: String.t() | nil
  defp current_active_tool_name([]), do: nil

  defp current_active_tool_name(active_tool_calls) do
    {_tool_call_id, name} = List.last(active_tool_calls)
    name
  end

  @spec tool_name_for_call([active_tool_call()], String.t()) :: String.t()
  defp tool_name_for_call(active_tool_calls, tool_call_id) do
    case Enum.find(active_tool_calls, fn {id, _name} -> id == tool_call_id end) do
      {_id, name} -> name
      nil -> "unknown"
    end
  end

  @spec plan_mode_message() :: String.t()
  defp plan_mode_message do
    "Plan mode enabled. Destructive tools are blocked before execution. Read-only and search tools still work. Use /exec when you are ready to make changes."
  end

  @spec exec_mode_message() :: String.t()
  defp exec_mode_message do
    "Execution mode enabled. Destructive tools can run again after normal approval checks. Use /plan to return to planning."
  end

  # ── Remote attachment roles ────────────────────────────────────────────────

  @spec default_subscriber_role(state()) :: attachment_role()
  defp default_subscriber_role(%{driver: nil}), do: :driver
  defp default_subscriber_role(_state), do: :viewer

  @spec put_subscriber(state(), pid(), attachment_role()) :: state()
  defp put_subscriber(state, pid, :driver) do
    state = %{state | subscribers: MapSet.put(state.subscribers, pid)}

    case state.driver do
      nil -> set_driver(state, pid)
      ^pid -> set_driver(state, pid)
      _other -> put_subscriber(state, pid, :viewer)
    end
  end

  defp put_subscriber(state, pid, :viewer) do
    %{
      state
      | subscribers: MapSet.put(state.subscribers, pid),
        subscriber_roles: Map.put(state.subscriber_roles, pid, :viewer)
    }
  end

  @spec claim_driver_role(state(), pid()) ::
          {:ok, state()} | {:error, :driver_taken | :not_subscribed}
  defp claim_driver_role(state, pid) do
    claim_driver_role(state, pid, MapSet.member?(state.subscribers, pid), state.driver)
  end

  @spec claim_driver_role(state(), pid(), boolean(), pid() | nil) ::
          {:ok, state()} | {:error, :driver_taken | :not_subscribed}
  defp claim_driver_role(_state, _pid, false, _driver), do: {:error, :not_subscribed}
  defp claim_driver_role(state, pid, true, nil), do: {:ok, set_driver(state, pid)}
  defp claim_driver_role(state, pid, true, pid), do: {:ok, set_driver(state, pid)}
  defp claim_driver_role(_state, _pid, true, _driver), do: {:error, :driver_taken}

  @spec set_driver(state(), pid()) :: state()
  defp set_driver(%{driver: nil, subscriber_roles: roles} = state, pid)
       when map_size(roles) == 0 do
    %{
      state
      | driver: pid,
        subscriber_roles: Map.put(state.subscriber_roles, pid, :driver)
    }
  end

  defp set_driver(state, pid) do
    state = %{
      state
      | driver: pid,
        subscriber_roles: Map.put(state.subscriber_roles, pid, :driver)
    }

    broadcast(state, {:driver_changed, pid})
    state
  end

  @spec remove_subscriber(state(), pid()) :: state()
  defp remove_subscriber(state, pid) do
    driver = if state.driver == pid, do: nil, else: state.driver

    %{
      state
      | subscribers: MapSet.delete(state.subscribers, pid),
        subscriber_roles: Map.delete(state.subscriber_roles, pid),
        driver: driver
    }
  end

  @spec driver_allowed?(state(), pid()) :: boolean()
  defp driver_allowed?(%{driver: pid}, pid) when is_pid(pid), do: true
  defp driver_allowed?(_state, _pid), do: false

  # ── Broadcasting ────────────────────────────────────────────────────────────

  @spec broadcast(state(), term()) :: :ok
  defp broadcast(state, event) do
    record_broadcast_event(state, event)
    session_pid = self()

    Enum.each(state.subscribers, fn pid ->
      send(pid, {:agent_event, session_pid, event})
    end)
  end

  @spec mark_interrupted_work(state()) :: :ok
  defp mark_interrupted_work(state) do
    with {:ok, db} <- EventLog.open_read_connection(),
         {:ok, events} <- all_event_log_events(db, state.session_id) do
      MingaAgent.EventLog.Store.close(db)
      record_interrupted_work(state, events)
    else
      _ -> :ok
    end
  end

  @spec all_event_log_events(EventLog.Store.db(), String.t(), non_neg_integer(), [
          EventLog.EventRecord.t()
        ]) ::
          {:ok, [EventLog.EventRecord.t()]} | {:error, term()}
  defp all_event_log_events(db, session_id, last_seen_event_id \\ 0, acc \\ []) do
    with {:ok, events} <- EventLog.events_after(db, session_id, last_seen_event_id, 1000) do
      case events do
        [] ->
          {:ok, Enum.reverse(acc)}

        _ ->
          all_event_log_events(db, session_id, List.last(events).id, Enum.reverse(events) ++ acc)
      end
    end
  end

  @spec record_interrupted_work(state(), [EventLog.EventRecord.t()]) :: :ok
  defp record_interrupted_work(state, events) do
    tool_ids = open_tool_call_ids(events)
    approval_ids = open_approval_ids(events)

    Enum.each(tool_ids, fn tool_call_id ->
      EventLog.record(
        state.session_id,
        :tool_call_interrupted,
        %{tool_call_id: tool_call_id},
        state.event_log_server
      )
    end)

    Enum.each(approval_ids, fn approval_id ->
      EventLog.record(
        state.session_id,
        :approval_interrupted,
        %{approval_id: approval_id, tool_call_id: approval_id},
        state.event_log_server
      )
    end)
  end

  @spec open_tool_call_ids([EventLog.EventRecord.t()]) :: [String.t()]
  defp open_tool_call_ids(events) do
    started = ids_for(events, :tool_call_started, "tool_call_id")

    closed =
      ids_for(events, :tool_call_finished, "tool_call_id") ++
        ids_for(events, :tool_call_interrupted, "tool_call_id")

    started -- closed
  end

  @spec open_approval_ids([EventLog.EventRecord.t()]) :: [String.t()]
  defp open_approval_ids(events) do
    requested = ids_for(events, :approval_requested, "approval_id")

    closed =
      ids_for(events, :approval_resolved, "approval_id") ++
        ids_for(events, :approval_interrupted, "approval_id")

    requested -- closed
  end

  @spec ids_for([EventLog.EventRecord.t()], EventLog.EventRecord.event_type(), String.t()) :: [
          String.t()
        ]
  defp ids_for(events, event_type, key) do
    events
    |> Enum.filter(&(&1.event_type == event_type))
    |> Enum.map(&Map.get(&1.payload, key))
    |> Enum.filter(&is_binary/1)
  end

  @spec record_broadcast_event(state(), term()) :: :ok
  defp record_broadcast_event(state, event) do
    case event_log_entry(event) do
      {event_type, payload} ->
        EventLog.record(state.session_id, event_type, payload, state.event_log_server)

      nil ->
        :ok
    end
  end

  @spec event_log_entry(term()) :: {EventLog.EventRecord.event_type(), map()} | nil
  defp event_log_entry({:text_delta, delta}), do: {:assistant_delta, %{delta: delta}}
  defp event_log_entry({:thinking_delta, delta}), do: {:thinking_delta, %{delta: delta}}

  defp event_log_entry({:tool_started, _name, _args}), do: nil

  defp event_log_entry({:tool_update, tool_call_id, name, partial_result}),
    do:
      {:tool_call_updated,
       %{tool_call_id: tool_call_id, name: name, partial_result: partial_result}}

  defp event_log_entry({:tool_ended, _name, _result, _status}), do: nil

  defp event_log_entry(
         {:file_changed, path, before_content, after_content, tool_call_id, tool_name}
       ),
       do:
         {:file_edit_proposed,
          %{
            path: path,
            before_content: before_content,
            after_content: after_content,
            tool_call_id: tool_call_id,
            tool_name: tool_name
          }}

  defp event_log_entry({:approval_pending, approval}),
    do: {:approval_requested, Map.put(approval, :approval_id, approval.tool_call_id)}

  defp event_log_entry({:approval_resolved, decision}),
    do: {:approval_resolved, %{decision: decision}}

  defp event_log_entry({:system_message, message, level}),
    do: {:system_message, %{message: message, level: level}}

  defp event_log_entry({:status_changed, :idle}), do: {:waiting_for_input, %{status: :idle}}
  defp event_log_entry({:status_changed, status}), do: {:status_changed, %{status: status}}

  defp event_log_entry({:prompt_queued, content, queue}),
    do: {:prompt_queued, %{content: content, queue: queue}}

  defp event_log_entry(:messages_changed), do: {:message_changed, %{changed: true}}
  defp event_log_entry({:error, message}), do: {:error, %{message: message}}

  defp event_log_entry({:context_usage, estimated_tokens, context_limit}),
    do: {:context_usage, %{estimated_tokens: estimated_tokens, context_limit: context_limit}}

  defp event_log_entry({:turn_limit_reached, current, limit}),
    do: {:turn_limit_reached, %{current: current, limit: limit}}

  defp event_log_entry({:driver_changed, pid}),
    do: {:driver_changed, %{driver_present: is_pid(pid)}}

  defp event_log_entry({:tool_auto_approved, tool_call_id, name, scope}),
    do:
      {:approval_resolved,
       %{
         approval_id: tool_call_id,
         tool_call_id: tool_call_id,
         name: name,
         decision: :approve,
         scope: scope
       }}

  defp event_log_entry(_event), do: nil

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

  @spec record_user_message(state(), Message.t()) :: :ok
  defp record_user_message(state, {:user, text}) do
    EventLog.record(
      state.session_id,
      :user_message,
      %{text: text, attachments: []},
      state.event_log_server
    )
  end

  defp record_user_message(state, {:user, text, attachments}) do
    EventLog.record(
      state.session_id,
      :user_message,
      %{text: text, attachments: attachments},
      state.event_log_server
    )
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
    state = %{state | last_message_at: DateTime.utc_now()}
    broadcast(state, :messages_changed)
    schedule_save(state)
  end

  @spec seed_provider_messages(state(), [Message.t()]) :: state()
  defp seed_provider_messages(%{provider: provider, provider_module: module} = state, messages)
       when is_pid(provider) do
    case module.seed_messages(provider, messages) do
      :ok ->
        state

      {:error, reason} ->
        append_system_message(
          state,
          "Failed to seed provider context: #{inspect(reason)}",
          :error
        )
    end
  catch
    :exit, reason ->
      append_system_message(state, "Failed to seed provider context: #{inspect(reason)}", :error)
  end

  defp seed_provider_messages(state, _messages), do: state

  # ── Provider startup ────────────────────────────────────────────────────────

  @spec start_provider(state()) :: {:ok, pid()} | {:error, term()}
  defp start_provider(state) do
    state.provider_module.start_link(state.provider_opts)
  end

  @spec initial_system_message(String.t(), String.t() | nil) :: String.t()
  defp initial_system_message(timestamp, nil), do: "Session started · #{timestamp}"
  defp initial_system_message(timestamp, notice), do: "Session started · #{timestamp} · #{notice}"

  @spec build_subagent_context(state()) :: subagent_context()
  defp build_subagent_context(state) do
    provider_state = provider_state(state)

    SubagentContext.new(
      provider_module: state.provider_module,
      provider_name: provider_name(provider_state, state),
      model: provider_model(provider_state, state),
      thinking_level: provider_thinking_level(provider_state),
      active_skill_names: provider_active_skill_names(provider_state),
      project_root: provider_project_root(provider_state, state)
    )
  end

  @spec provider_state(state()) :: map()
  defp provider_state(%{provider: nil}), do: %{}

  defp provider_state(state) do
    case state.provider_module.get_state(state.provider) do
      {:ok, provider_state} when is_map(provider_state) -> provider_state
      _other -> %{}
    end
  catch
    :exit, reason ->
      Minga.Log.warning(
        :agent,
        "[Session] provider unreachable for subagent context: #{inspect(reason)}"
      )

      %{}
  end

  @spec provider_name(map(), state()) :: String.t()
  defp provider_name(%{model: %{provider: provider}}, _state) when is_binary(provider),
    do: provider

  defp provider_name(%{provider: provider}, _state) when is_binary(provider), do: provider
  defp provider_name(_provider_state, state), do: state.provider_name

  @spec provider_model(map(), state()) :: String.t() | nil
  defp provider_model(%{model: %{id: id}}, _state) when is_binary(id), do: id
  defp provider_model(%{model: model}, _state) when is_binary(model), do: model
  defp provider_model(_provider_state, %{model_name: "unknown"}), do: nil
  defp provider_model(_provider_state, state), do: state.model_name

  @spec provider_thinking_level(map()) :: String.t() | nil
  defp provider_thinking_level(%{thinking_level: level}) when is_binary(level), do: level
  defp provider_thinking_level(_provider_state), do: nil

  @spec provider_active_skill_names(map()) :: [String.t()]
  defp provider_active_skill_names(%{active_skill_names: names}) when is_list(names) do
    Enum.filter(names, &is_binary/1)
  end

  defp provider_active_skill_names(_provider_state), do: []

  @spec provider_project_root(map(), state()) :: String.t() | nil
  defp provider_project_root(%{project_root: project_root}, _state)
       when is_binary(project_root) do
    project_root
  end

  defp provider_project_root(_provider_state, state) do
    case Keyword.get(state.provider_opts, :project_root) do
      project_root when is_binary(project_root) -> project_root
      _other -> nil
    end
  end

  @spec format_error(term()) :: String.t()
  defp format_error({:spawn_failed, msg}), do: "Failed to start agent: #{msg}"
  defp format_error(reason), do: inspect(reason)

  # Recomputes whether any provider credential is configured, stores it, and
  # tells subscribers so the UI can reflect a truthful "not configured" state.
  # `Credentials.any_configured?/0` may block briefly (Ollama probe) so this
  # runs in the session process, off the render path.
  @spec refresh_credentials_state(state()) :: state()
  defp refresh_credentials_state(state) do
    # Only the native provider resolves its own credentials from the
    # environment. Custom providers, and any caller that injects its own
    # `:llm_client` (tests, embedded transports), manage their own auth, so
    # treat them as always ready.
    configured? =
      state.provider_module != MingaAgent.Providers.Native or
        Keyword.has_key?(state.provider_opts, :llm_client) or
        Credentials.any_configured?()

    state = %{state | credentials_configured: configured?}
    broadcast(state, {:credentials_status, configured?})
    state
  end

  # Shows an onboarding message when no credentials are configured and the
  # native provider is active. Only fires once per session. Relies on the
  # `credentials_configured` flag set by `refresh_credentials_state/1`.
  @spec maybe_show_auth_onboarding(state()) :: state()
  defp maybe_show_auth_onboarding(state) do
    if state.provider_module == MingaAgent.Providers.Native and not state.credentials_configured do
      msg = onboarding_message()
      state = append_msg(state, Message.system(msg))
      broadcast(state, {:system_message, msg, :info})
      state
    else
      state
    end
  end

  @spec onboarding_message() :: String.t()
  defp onboarding_message do
    """
    Welcome to Minga. Set up a provider to get started.

    Add an API key (works with any supported provider):

      /auth anthropic <key>     Anthropic Claude
      /auth openai <key>        OpenAI GPT
      /auth google <key>        Google Gemini
      /auth openrouter <key>    OpenRouter (many models)
      /auth groq <key>          Groq
      /auth deepseek <key>      DeepSeek

    Or sign in with a ChatGPT subscription (OpenAI accounts only):

      /login                    Sign in via browser, no key needed

    Ollama is detected automatically if it's running locally.
    Run /auth to see status for all providers.\
    """
  end

  # Shown when the user submits a prompt before any provider is configured.
  @spec auth_required_message() :: String.t()
  defp auth_required_message do
    """
    No provider is configured yet, so there's nothing to send your message to.

    Set one up to get started:

      /auth anthropic <key>     add an API key (most common)
      /login                    ChatGPT subscription (OpenAI only)

    Run /auth to see all providers and options.\
    """
  end

  # Turns a raw provider error (the ugly ReqLLM struct dump) into one human
  # line for the transcript. The full detail is still logged to the Messages
  # panel by the provider. Already human-readable messages (MCP notices, hook
  # vetoes, turn/cost limits) are passed through unchanged.
  @spec humanize_error(String.t()) :: String.t()
  defp humanize_error(message) when is_binary(message) do
    humanize_error(
      message,
      provider_rejected_key?(message),
      rate_limited?(message),
      auth_failed?(message),
      provider_unreachable?(message),
      raw_struct_dump?(message)
    )
  end

  defp humanize_error(message), do: humanize_error(inspect(message))

  @spec humanize_error(String.t(), boolean(), boolean(), boolean(), boolean(), boolean()) ::
          String.t()
  defp humanize_error(_message, true, _rate_limited?, _auth_failed?, _unreachable?, _raw_dump?) do
    "The provider rejected your API key. Update it with /auth <provider> <key>, then try again."
  end

  defp humanize_error(_message, false, true, _auth_failed?, _unreachable?, _raw_dump?) do
    "Rate limited by the provider. Wait a moment and try again."
  end

  defp humanize_error(_message, false, false, true, _unreachable?, _raw_dump?) do
    "Couldn't authenticate with the model provider. Check your API key with /auth, then try again."
  end

  defp humanize_error(_message, false, false, false, true, _raw_dump?) do
    "Couldn't reach the model provider. Check your network connection and try again."
  end

  defp humanize_error(_message, false, false, false, false, true) do
    "Something went wrong talking to the model provider. Open the Messages panel for details."
  end

  defp humanize_error(message, false, false, false, false, false), do: message

  @spec provider_rejected_key?(String.t()) :: boolean()
  defp provider_rejected_key?(message) do
    String.match?(message, ~r/\b401\b/) or
      String.contains?(message, ["unauthorized", "Unauthorized", "invalid_api_key"])
  end

  @spec rate_limited?(String.t()) :: boolean()
  defp rate_limited?(message) do
    String.match?(message, ~r/\b429\b/) or String.contains?(message, "rate limit")
  end

  @spec auth_failed?(String.t()) :: boolean()
  defp auth_failed?(message) do
    String.contains?(message, ["api_key", "API_KEY", "provider_build_failed", "Failed to build"])
  end

  @spec provider_unreachable?(String.t()) :: boolean()
  defp provider_unreachable?(message) do
    String.contains?(message, ["http_streaming_failed", "econnrefused", "nxdomain", "timed out"])
  end

  # Detects an inspected Elixir struct/exception leaking into the message, so
  # we never show a raw `%ReqLLM.Error{...}`-style dump in the transcript.
  @spec raw_struct_dump?(String.t()) :: boolean()
  defp raw_struct_dump?(message) do
    String.contains?(message, ["%ReqLLM.", "Splode", "bread_crumbs", "stacktrace:", "#PID<"])
  end

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
  # to the ProviderResolver which checks config.
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
  defp schedule_save(%{persist?: false} = state), do: state

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

  @spec save_to_disk(state()) :: :ok | {:error, term()}
  defp save_to_disk(state) do
    now = DateTime.to_iso8601(DateTime.utc_now())
    last_message_at = DateTime.to_iso8601(state.last_message_at)

    data = %{
      id: state.session_id,
      remote_token: state.remote_token,
      timestamp: now,
      last_message_at: last_message_at,
      title: readable_title(first_user_prompt(state.messages)),
      model_name: state.model_name,
      provider_name: state.provider_name,
      messages: state.messages,
      usage: state.total_usage,
      branches: state.branches,
      memory: Memory.read(state.session_store_dir)
    }

    SessionStore.save(data, state.session_store_dir)
  end

  @spec restore_loaded_session(state(), SessionStore.session_data()) ::
          {:ok, state()} | {:error, term()}
  defp restore_loaded_session(state, data) do
    case persist_current_before_replacement(state, data.id) do
      :ok ->
        state = cancel_save_timer(state)
        loaded_at = parse_datetime(Map.get(data, :last_message_at)) || DateTime.utc_now()

        state = %{
          state
          | session_id: data.id,
            remote_token: Map.get(data, :remote_token, state.remote_token),
            total_usage: data.usage,
            model_name: data.model_name,
            provider_name: Map.get(data, :provider_name, state.provider_name),
            status: :idle,
            error_message: nil,
            pending_approval: nil,
            active_tool_calls: [],
            active_tool_name: nil,
            created_at: loaded_at,
            last_message_at: loaded_at,
            branches: Map.get(data, :branches, []),
            steering_queue: [],
            follow_up_queue: [],
            touched_files: %{},
            boundaries: %{},
            trust_levels: %{},
            pending_auto_approvals: %{}
        }

        apply_loaded_model_to_provider(state)
        finish_loaded_session_restore(state, data)

      {:error, reason} ->
        {:error, {:save_current_failed, reason}}
    end
  end

  @spec finish_loaded_session_restore(state(), SessionStore.session_data()) ::
          {:ok, state()} | {:error, term()}
  defp finish_loaded_session_restore(state, data) do
    case restore_memory_snapshot_if_recorded(state, data) do
      :ok ->
        state = reset_messages(state, data.messages)

        broadcast(state, {:status_changed, :idle})
        broadcast(state, :messages_changed)
        {:ok, state}

      {:error, reason} ->
        {:error, {:memory_restore_failed, reason}}
    end
  end

  @spec persist_current_before_replacement(state(), String.t()) :: :ok | {:error, term()}
  defp persist_current_before_replacement(%{session_id: target_id}, target_id), do: :ok
  defp persist_current_before_replacement(state, _target_id), do: save_to_disk(state)

  @spec apply_loaded_model_to_provider(state()) :: :ok
  defp apply_loaded_model_to_provider(%{provider: nil}), do: :ok

  defp apply_loaded_model_to_provider(state) do
    dispatch_optional(state.provider_module, :set_model, [state.provider, state.model_name])
    :ok
  catch
    :exit, _ -> :ok
  end

  @spec restore_memory_snapshot_if_recorded(state(), SessionStore.session_data()) ::
          :ok | {:error, term()}
  defp restore_memory_snapshot_if_recorded(state, data) do
    if Map.has_key?(data, :memory) do
      restore_memory_snapshot(state, Map.get(data, :memory))
    else
      :ok
    end
  end

  @spec restore_memory_snapshot(state(), String.t() | nil) :: :ok | {:error, term()}
  defp restore_memory_snapshot(state, nil), do: Memory.clear(state.session_store_dir)

  defp restore_memory_snapshot(state, memory) when is_binary(memory) do
    path = Memory.path(state.session_store_dir)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, memory)
    end
  end

  @spec parse_datetime(String.t() | nil) :: DateTime.t() | nil
  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  @spec count_user_turns([Message.t()]) :: non_neg_integer()
  defp count_user_turns(messages) do
    Enum.count(messages, fn
      {:user, _} -> true
      {:user, _, _attachments} -> true
      _ -> false
    end)
  end

  @spec readable_title(String.t() | nil) :: String.t() | nil
  defp readable_title(nil), do: nil

  defp readable_title(text) do
    text
    |> String.split("\n")
    |> hd()
    |> String.trim()
    |> case do
      "" -> nil
      title -> title
    end
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
    model = state.model_name |> AgentConfig.strip_provider_prefix() |> titleize()

    cache_part =
      if cr > 0 or cw > 0 do
        " cache:#{format_k(cr)}/#{format_k(cw)}"
      else
        ""
      end

    Minga.Events.broadcast(:log_message, %Minga.Events.LogMessageEvent{
      text:
        "[Agent] #{provider}/#{model} turn: in:#{format_k(i)} out:#{format_k(o)}#{cache_part} cost:$#{Float.round(cost, 4)}",
      level: :info
    })
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

  # Records a file touch from a ToolFileChanged event.
  @spec record_file_touch(state(), String.t(), String.t(), String.t()) :: state()
  defp record_file_touch(state, path, "", after_content) when byte_size(after_content) > 0 do
    record_file_touch_with_action(state, path, :created)
  end

  defp record_file_touch(state, path, before_content, "") when byte_size(before_content) > 0 do
    record_file_touch_with_action(state, path, :deleted)
  end

  defp record_file_touch(state, path, _before, _after) do
    record_file_touch_with_action(state, path, :modified)
  end

  @spec record_file_touch_with_action(state(), String.t(), :created | :modified | :deleted) ::
          state()
  defp record_file_touch_with_action(state, path, action) do
    touch = %{
      path: path,
      action: action,
      timestamp: System.monotonic_time()
    }

    touched_files = Map.put(state.touched_files, path, touch)
    %{state | touched_files: touched_files}
  end

  @impl GenServer
  def terminate(reason, state) do
    EventLog.record(
      state.session_id,
      :session_stopped,
      %{reason: inspect(reason), status: state.status},
      state.event_log_server
    )

    dispatch_session_end(state, reason)

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

  # ── Hook dispatching ──────────────────────────────────────────────────────

  @spec dispatch_session_start(state()) :: :ok
  defp dispatch_session_start(%{hooks_enabled?: false}), do: :ok
  defp dispatch_session_start(%{session_start_hook_enabled?: false}), do: :ok

  defp dispatch_session_start(state) do
    payload = SessionStartPayload.new(state.session_id, state.model_name, state.provider_name)

    HookDispatcher.session_start(
      AgentConfig.resolve().agent_hooks,
      SessionStartPayload.to_map(payload)
    )
  rescue
    e -> Minga.Log.warning(:agent, "SessionStart hook dispatch failed: #{Exception.message(e)}")
  catch
    _, reason ->
      Minga.Log.warning(:agent, "SessionStart hook dispatch failed: #{inspect(reason)}")
  end

  @spec dispatch_session_end(state(), term()) :: :ok
  defp dispatch_session_end(%{hooks_enabled?: false}, _reason), do: :ok

  defp dispatch_session_end(state, reason) do
    payload = SessionEndPayload.new(state.session_id, reason, state.status)

    HookDispatcher.session_end(
      AgentConfig.resolve().agent_hooks,
      SessionEndPayload.to_map(payload)
    )
  rescue
    e -> Minga.Log.warning(:agent, "SessionEnd hook dispatch failed: #{Exception.message(e)}")
  catch
    _, caught ->
      Minga.Log.warning(:agent, "SessionEnd hook dispatch failed: #{inspect(caught)}")
  end

  @spec dispatch_stop(state()) :: :ok
  defp dispatch_stop(%{hooks_enabled?: false}), do: :ok

  defp dispatch_stop(state) do
    last_message = extract_last_assistant_text(state.messages)
    payload = StopPayload.new(state.session_id, :end_turn, last_message)
    HookDispatcher.stop(AgentConfig.resolve().agent_hooks, StopPayload.to_map(payload))
  rescue
    e -> Minga.Log.warning(:agent, "Stop hook dispatch failed: #{Exception.message(e)}")
  catch
    _, reason -> Minga.Log.warning(:agent, "Stop hook dispatch failed: #{inspect(reason)}")
  end

  @spec dispatch_notification(state(), atom(), String.t()) :: :ok
  defp dispatch_notification(%{hooks_enabled?: false}, _trigger, _message), do: :ok

  defp dispatch_notification(state, trigger, message) do
    payload = NotificationPayload.new(state.session_id, trigger, message)

    HookDispatcher.notification(
      AgentConfig.resolve().agent_hooks,
      NotificationPayload.to_map(payload)
    )
  rescue
    e -> Minga.Log.warning(:agent, "Notification hook dispatch failed: #{Exception.message(e)}")
  catch
    _, reason ->
      Minga.Log.warning(:agent, "Notification hook dispatch failed: #{inspect(reason)}")
  end

  @spec dispatch_user_prompt_submit(state(), String.t() | [term()]) ::
          :ok | {:error, HookResult.t()}
  defp dispatch_user_prompt_submit(%{hooks_enabled?: false}, _content), do: :ok

  defp dispatch_user_prompt_submit(state, content) do
    payload = UserPromptSubmitPayload.new(state.session_id, content)

    HookDispatcher.user_prompt_submit(
      AgentConfig.resolve().agent_hooks,
      UserPromptSubmitPayload.to_map(payload)
    )
  rescue
    e ->
      Minga.Log.warning(:agent, "UserPromptSubmit hook dispatch failed: #{Exception.message(e)}")
      {:error, HookResult.dispatch_error(Exception.message(e))}
  catch
    _, caught ->
      Minga.Log.warning(:agent, "UserPromptSubmit hook dispatch failed: #{inspect(caught)}")
      {:error, HookResult.dispatch_error(inspect(caught))}
  end

  @spec extract_last_assistant_text([Message.t()]) :: String.t() | nil
  defp extract_last_assistant_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      {:assistant, content} when is_binary(content) -> content
      _ -> nil
    end)
  end
end
