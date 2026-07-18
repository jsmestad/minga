defmodule MingaAgent.Session do
  @moduledoc """
  Manages the lifecycle of one AI agent conversation.

  The session holds conversation history, tracks agent status, and coordinates between the provider and the editor UI. Each session is supervised independently under `MingaAgent.Supervisor`.

  ## Status lifecycle

      :idle → :thinking → :tool_executing → :thinking → ... → :idle
                 ↓                              ↓
              :error                          :error

  ## Subscribing to events

  Call `subscribe/2` with a pid to receive `{:agent_event, session_pid, event}`
  messages. The editor uses this to update the modeline and chat panel.
  """

  use GenServer

  alias Minga.Config.Options
  alias MingaAgent.Branch
  alias Minga.Extension.CodeLease
  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Credentials
  alias MingaAgent.Event
  alias MingaAgent.EventLog
  alias MingaAgent.EventLog.Failure
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
  alias MingaAgent.ProviderRegistry
  alias MingaAgent.ProviderResolver
  alias MingaAgent.SessionMetadata
  alias MingaAgent.Session.ProviderLifecycle
  alias MingaAgent.Session.Persistence
  alias MingaAgent.Session.SubscriberAttachment
  alias MingaAgent.Session.SubscriberLifecycle
  alias MingaAgent.Session.Transcript
  alias MingaAgent.Session.TurnExecution
  require ProviderLifecycle
  alias MingaAgent.SessionStore
  alias MingaAgent.SubagentContext
  alias MingaAgent.ToolApproval
  alias MingaAgent.ToolCall

  @typedoc "Agent session status."
  @type status :: TurnExecution.status()

  @typedoc "Pending tool approval data."
  @type pending_approval :: MingaAgent.ToolApproval.t()

  @typedoc "Tool trust lifetime."
  @type trust_scope :: TurnExecution.trust_scope()

  @typedoc "Context inherited by child subagent sessions."
  @type subagent_context :: SubagentContext.t()

  @typedoc "Callback that reports whether credentials are currently configured."
  @type credentials_configured_fn :: (-> boolean())

  @typedoc "Remote attachment role."
  @type attachment_role :: SubscriberLifecycle.role()

  @typedoc "Latest EventLog admission or persistence failure retained for reconnecting subscribers."
  @type event_log_failure :: Failure.t()

  @typedoc "How a session handles tool approvals when no interactive driver should answer them."
  @type tool_approval_policy ::
          :interactive | {:auto_approve, trust_scope()} | {:reject, String.t()}

  @typedoc "Internal session state."
  @type state :: %{
          session_id: String.t(),
          workdir: String.t() | nil,
          event_log_server: GenServer.server(),
          event_log_failure: event_log_failure() | nil,
          provider: ProviderLifecycle.t(),
          credentials_configured_fn: credentials_configured_fn(),
          turn_execution: TurnExecution.t(),
          transcript: Transcript.t(),
          subscriber_lifecycle: SubscriberLifecycle.t(),
          tool_approval_policy: tool_approval_policy(),
          idle_gc_timeout_ms: non_neg_integer(),
          persistence: Persistence.t(),
          pending_thinking_level: String.t() | nil,
          notifier: module() | {module(), term()},
          background_subagent: boolean(),
          hooks_enabled?: boolean(),
          session_start_hook_enabled?: boolean(),
          session_store_dir: String.t() | nil,
          created_at: DateTime.t(),
          credentials_configured: boolean()
        }

  @provider_stop_timeout_ms 1_000
  @provider_restart_options [
    provider_restart_backoff_base_ms: :base_delay_ms,
    provider_restart_backoff_max_ms: :max_delay_ms,
    provider_restart_max_attempts: :max_attempts,
    provider_restart_window_ms: :window_ms
  ]

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

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

  @doc "Retries provider startup immediately, resetting any exhausted restart backoff."
  @spec restart_provider(GenServer.server()) :: :ok | {:error, term()}
  def restart_provider(session) do
    GenServer.call(session, :restart_provider)
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

  @doc "Returns the set of pinned message IDs."
  @spec pinned_ids(GenServer.server()) :: MapSet.t(pos_integer())
  def pinned_ids(session) do
    GenServer.call(session, :pinned_ids)
  end

  @doc "Toggles the pinned state of a message by its stable ID."
  @spec toggle_pin(GenServer.server(), pos_integer()) :: :ok
  def toggle_pin(session, message_id) when is_integer(message_id) do
    GenServer.call(session, {:toggle_pin, message_id})
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
          active_tool_name: String.t() | nil,
          credentials_configured: boolean()
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
  @typep approval_resolution :: {state(), ToolApproval.t(), approval_decision()}

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
  @spec subscribe(GenServer.server()) :: :ok | {:error, :invalid_role}
  def subscribe(session) do
    subscribe(session, self())
  end

  @doc "Subscribes the given process to session events."
  @spec subscribe(GenServer.server(), pid(), keyword()) :: :ok | {:error, :invalid_role}
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
    unsubscribe(session, self())
  end

  @doc "Unsubscribes the given process from session events."
  @spec unsubscribe(GenServer.server(), pid()) :: :ok
  def unsubscribe(session, pid) when is_pid(pid) do
    GenServer.call(session, {:unsubscribe, pid})
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

  @doc """
  Sets the model without resetting conversation context.

  Setting a model can start the provider synchronously (see `start_provider/1`),
  so callers may pass a larger `timeout` when a slow provider startup should not
  surface as a call timeout.
  """
  @spec set_model(GenServer.server(), String.t(), timeout()) :: :ok | {:error, term()}
  def set_model(session, model, timeout \\ 5_000) when is_binary(model) do
    GenServer.call(session, {:set_model, model}, timeout)
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
  @dialyzer {:no_opaque, init: 1}
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    Minga.Telemetry.span([:minga, :agent, :session_init], %{}, fn ->
      do_init(opts)
    end)
  end

  @spec do_init(keyword()) :: {:ok, state()}
  defp do_init(opts) do
    Process.flag(:trap_exit, true)

    provider_opts =
      Keyword.merge(
        [subscriber: self()],
        Keyword.get(opts, :provider_opts, [])
      )

    credentials_configured_fn =
      Keyword.get(opts, :credentials_configured_fn, &Credentials.any_configured?/0)

    initial_thinking_level = Keyword.get(opts, :thinking_level)
    timestamp = Calendar.strftime(DateTime.utc_now(), "%H:%M:%S UTC")

    session_id = Keyword.get(opts, :session_id, generate_session_id())
    model_name = session_model_name(opts, provider_opts)
    resolved_provider_resolution = resolve_provider(opts)

    credentials_configured? =
      session_credentials_configured?(
        resolved_provider_resolution.module,
        provider_opts,
        credentials_configured_fn
      )

    provider_resolution =
      if credentials_configured?,
        do: resolved_provider_resolution,
        else: unconfigured_provider_resolution()

    provider_module = provider_resolution.module

    {provider_name, provider_opts} =
      session_provider_configuration(provider_module, model_name, provider_opts)

    provider_lease =
      if credentials_configured? do
        acquire_provider_lease!(
          provider_resolution.source,
          provider_module,
          provider_resolution.id
        )
      end

    provider =
      ProviderLifecycle.new(
        module: provider_module,
        id: provider_resolution.id,
        source: provider_resolution.source,
        provider_opts: provider_opts,
        model_name: model_name,
        provider_name: provider_name,
        lease: provider_lease,
        restart: provider_restart_options(opts)
      )

    now = DateTime.utc_now()

    state = %{
      session_id: session_id,
      workdir: Keyword.get(opts, :workdir),
      event_log_server: Keyword.get(opts, :event_log_server, EventLog),
      event_log_failure: nil,
      provider: provider,
      credentials_configured_fn: credentials_configured_fn,
      turn_execution: TurnExecution.new(),
      transcript:
        Transcript.new(
          [Message.system(initial_system_message(timestamp, Keyword.get(opts, :startup_notice)))],
          now
        ),
      subscriber_lifecycle: SubscriberLifecycle.new(),
      tool_approval_policy: Keyword.get(opts, :tool_approval_policy, :interactive),
      idle_gc_timeout_ms: Keyword.get_lazy(opts, :idle_gc_timeout_ms, &idle_gc_timeout_ms/0),
      persistence: Persistence.new(Keyword.get(opts, :persist?, true)),
      pending_thinking_level: initial_thinking_level,
      notifier: Keyword.get(opts, :notifier, Notifier),
      background_subagent: Keyword.get(opts, :background_subagent, false),
      hooks_enabled?: Keyword.get(opts, :hooks_enabled?, true),
      session_start_hook_enabled?:
        Keyword.get(opts, :session_start_hook_enabled?, Keyword.get(opts, :hooks_enabled?, true)),
      session_store_dir: Keyword.get(opts, :session_store_dir),
      created_at: now,
      credentials_configured: credentials_configured?
    }

    maybe_mark_interrupted_work(state, Keyword.get(opts, :recover_interrupted_work?, true))

    record_critical_event(state, :session_started, %{
      model: state.provider.model_name,
      provider: state.provider.provider_name,
      background_subagent: state.background_subagent
    })

    # Start provider asynchronously so init doesn't block. An unconfigured local
    # session is still useful for draft preservation, but must not boot a provider.
    if credentials_configured? do
      send(self(), :start_provider)
    end

    {:ok, maybe_schedule_idle_gc(state)}
  end

  @impl GenServer
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call({:seed_messages, messages}, _from, state) do
    state =
      state
      |> append_msgs(messages)
      |> seed_provider_messages(messages)
      |> notify_messages_changed()

    {:reply, :ok, state}
  end

  def handle_call({:send_prompt_as, client_pid, content}, _from, state) do
    if driver_allowed?(state, client_pid) do
      handle_prompt(content, :steering, state)
    else
      {:reply, {:error, :not_driver}, state}
    end
  end

  def handle_call({:send_prompt, content}, _from, state) do
    handle_prompt(content, :steering, state)
  end

  def handle_call({:send_follow_up, content}, _from, state) do
    handle_prompt(content, :follow_up, state)
  end

  def handle_call(:dequeue_steering, _from, state) do
    {steering, execution} = TurnExecution.dequeue_steering(state.turn_execution)
    state = append_steering_messages(state, steering)
    {:reply, steering, %{state | turn_execution: execution}}
  end

  def handle_call(:recall_queues, _from, state) do
    {queues, execution} = TurnExecution.recall_queues(state.turn_execution)
    state = broadcast(state, :queues_recalled)
    {:reply, queues, %{state | turn_execution: execution}}
  end

  def handle_call(:clear_queues, _from, state) do
    execution = TurnExecution.clear_queues(state.turn_execution)
    state = broadcast(state, :queues_recalled)
    {:reply, :ok, %{state | turn_execution: execution}}
  end

  def handle_call(:get_queued_messages, _from, state) do
    {:reply, TurnExecution.queues(state.turn_execution), state}
  end

  def handle_call({:set_boundary, path, start_line, end_line}, _from, state) do
    case TurnExecution.set_boundary(state.turn_execution, path, start_line, end_line) do
      {:ok, execution} -> {:reply, :ok, %{state | turn_execution: execution}}
      {:error, _message} = error -> {:reply, error, state}
    end
  end

  def handle_call({:clear_boundary, path}, _from, state) do
    execution = TurnExecution.clear_boundary(state.turn_execution, path)
    {:reply, :ok, %{state | turn_execution: execution}}
  end

  def handle_call(:clear_all_boundaries, _from, state) do
    execution = TurnExecution.clear_boundaries(state.turn_execution)
    {:reply, :ok, %{state | turn_execution: execution}}
  end

  def handle_call({:boundary_for, path}, _from, state) do
    {:reply, TurnExecution.boundary(state.turn_execution, path), state}
  end

  def handle_call(:abort, _from, %{provider: provider} = state)
      when ProviderLifecycle.is_detached(provider) do
    {:reply, :ok, state}
  end

  def handle_call(:abort, _from, state) do
    {:reply, :ok, abort_turn(state)}
  end

  def handle_call(:new_session, _from, state) do
    if ProviderLifecycle.pid(state.provider) do
      state.provider.module.new_session(ProviderLifecycle.pid(state.provider))
    end

    record_critical_event(state, :session_stopped, %{
      reason: "new_session",
      status: TurnExecution.status(state.turn_execution)
    })

    now = DateTime.utc_now()
    timestamp = Calendar.strftime(now, "%H:%M:%S UTC")

    state = cancel_save_timer(state)
    source_execution = state.turn_execution
    execution = TurnExecution.reset(source_execution)

    state = %{
      state
      | session_id: generate_session_id(),
        created_at: now
    }

    transcript =
      state.transcript
      |> Transcript.reset([Message.system("Session cleared · #{timestamp}")])
      |> Transcript.touch(now)

    state = %{state | transcript: transcript}

    record_critical_event(state, :session_started, %{
      model: state.provider.model_name,
      provider: state.provider.provider_name,
      background_subagent: state.background_subagent
    })

    state =
      state
      |> reject_execution_approval(source_execution)
      |> announce_turn_status(execution)

    state = %{state | turn_execution: execution}
    {:reply, :ok, notify_messages_changed(state)}
  end

  def handle_call(:session_id, _from, state) do
    {:reply, state.session_id, state}
  end

  def handle_call(:enter_plan, _from, state) do
    {:reply, :ok, enter_plan_mode(state)}
  end

  def handle_call(:enter_exec, _from, state) do
    case TurnExecution.enter_exec(state.turn_execution) do
      {:changed, execution} -> {:reply, :ok, enter_exec_mode(state, execution)}
      :unchanged -> {:reply, :ok, state}
    end
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
    {:reply, TurnExecution.status(state.turn_execution), state}
  end

  def handle_call(:subagent_context, _from, state) do
    {:reply, build_subagent_context(state), state}
  end

  def handle_call(:messages, _from, state) do
    {:reply, Transcript.messages(state.transcript), state}
  end

  def handle_call(:messages_with_ids, _from, state) do
    {:reply, Transcript.messages_with_ids(state.transcript), state}
  end

  def handle_call(:usage, _from, state) do
    {:reply, Transcript.usage(state.transcript), state}
  end

  def handle_call(:pinned_ids, _from, state) do
    {:reply, Transcript.pinned_ids(state.transcript), state}
  end

  def handle_call({:toggle_pin, message_id}, _from, state) do
    transcript = Transcript.toggle_pin(state.transcript, message_id)
    state = %{state | transcript: transcript}
    broadcast(state, :messages_changed)
    {:reply, :ok, schedule_save(state)}
  end

  def handle_call(:get_provider, _from, state) do
    {:reply, ProviderLifecycle.pid(state.provider), state}
  end

  def handle_call(:persist?, _from, state) do
    {:reply, Persistence.enabled?(state.persistence), state}
  end

  def handle_call(:hooks_enabled?, _from, state) do
    {:reply, state.hooks_enabled?, state}
  end

  def handle_call(:editor_snapshot, _from, state) do
    snapshot = %{
      status: TurnExecution.status(state.turn_execution),
      pending_approval:
        public_pending_approval(TurnExecution.pending_approval(state.turn_execution)),
      error: TurnExecution.error(state.turn_execution),
      active_tool_name: TurnExecution.active_tool_name(state.turn_execution),
      credentials_configured: state.credentials_configured
    }

    {:reply, snapshot, state}
  end

  def handle_call(:metadata, _from, state) do
    first_prompt = first_user_prompt(Transcript.messages(state.transcript))

    title =
      readable_title(first_assistant_text(Transcript.messages(state.transcript))) ||
        readable_title(first_prompt)

    meta = %SessionMetadata{
      id: state.session_id,
      title: title,
      model_name: state.provider.model_name,
      provider_name: state.provider.provider_name,
      created_at: state.created_at,
      last_message_at: Transcript.last_changed_at(state.transcript),
      message_count: Enum.count(Transcript.messages(state.transcript)),
      turn_count: count_user_turns(Transcript.messages(state.transcript)),
      first_prompt: first_prompt,
      cost: Transcript.usage(state.transcript).cost,
      status: TurnExecution.status(state.turn_execution),
      workdir: state.workdir
    }

    {:reply, meta, state}
  end

  def handle_call({:respond_to_approval_as, client_pid, approval_id, decision}, _from, state) do
    if driver_allowed?(state, client_pid) do
      handle_approval_response(approval_id, decision, state)
    else
      {:reply, {:error, :not_driver}, state}
    end
  end

  def handle_call({:respond_to_approval, decision}, _from, state) do
    handle_approval_response(decision, state)
  end

  def handle_call({:set_tool_trust, name, scope}, _from, state) do
    execution = TurnExecution.put_trust(state.turn_execution, name, scope)
    {:reply, :ok, %{state | turn_execution: execution}}
  end

  def handle_call(:restart_provider, _from, state) do
    {lifecycle, effects} = ProviderLifecycle.reset_retry(state.provider)
    state = install_provider_transition(state, lifecycle, effects)

    {state, result} = refresh_credentials_state_result(state)

    case {ProviderLifecycle.pid(state.provider), result} do
      {provider, :ok} when is_pid(provider) ->
        {:reply, :ok, state}

      {_provider, :ok} when state.credentials_configured == false ->
        {:reply, {:error, :credentials_not_configured}, state}

      {_provider, :ok} ->
        {:reply, {:error, :provider_not_ready}, state}

      {_provider, {:error, reason}} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:revoke_tool_trust, :all}, _from, state) do
    execution = TurnExecution.revoke_trust(state.turn_execution, :all)
    {:reply, :ok, %{state | turn_execution: execution}}
  end

  def handle_call({:revoke_tool_trust, name}, _from, state) do
    execution = TurnExecution.revoke_trust(state.turn_execution, name)
    {:reply, :ok, %{state | turn_execution: execution}}
  end

  def handle_call(:list_tool_trust, _from, state) do
    {:reply, TurnExecution.trust_levels(state.turn_execution), state}
  end

  def handle_call({:subscribe, pid, opts}, _from, state) do
    role = Keyword.get(opts, :role, SubscriberLifecycle.default_role(state.subscriber_lifecycle))
    reply_to_subscribe(state, pid, role)
  end

  def handle_call({:subscriber_role, pid}, _from, state) do
    {:reply, SubscriberLifecycle.role(state.subscriber_lifecycle, pid), state}
  end

  def handle_call({:claim_driver, pid}, _from, state) do
    reply_to_claim_driver(state, pid)
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, detach_subscriber(state, pid, :detached)}
  end

  def handle_call(:compact, _from, %{provider: provider} = state)
      when ProviderLifecycle.is_detached(provider) do
    {:reply, {:error, "No active provider"}, state}
  end

  def handle_call(:compact, _from, state) do
    if function_exported?(state.provider.module, :compact, 1) do
      result = state.provider.module.compact(ProviderLifecycle.pid(state.provider))
      {:reply, result, state}
    else
      {:reply, {:error, "Provider does not support compaction"}, state}
    end
  end

  def handle_call(:continue, _from, %{provider: provider} = state)
      when ProviderLifecycle.is_detached(provider) do
    {:reply, {:error, "No active provider"}, state}
  end

  def handle_call(:continue, _from, state) do
    source_execution = state.turn_execution

    case TurnExecution.begin_turn(source_execution) do
      {:ok, execution} ->
        reply_to_continue(state, execution)

      {:error, :turn_active} ->
        reply_to_continue(state, nil)
    end
  end

  def handle_call(
        {:activate_skill, _name},
        _from,
        %{provider: provider} = state
      )
      when ProviderLifecycle.is_detached(provider) do
    {:reply, {:error, "No active provider"}, state}
  end

  def handle_call({:activate_skill, name}, _from, state) do
    result = GenServer.call(ProviderLifecycle.pid(state.provider), {:activate_skill, name})
    {:reply, result, state}
  end

  def handle_call(
        {:deactivate_skill, _name},
        _from,
        %{provider: provider} = state
      )
      when ProviderLifecycle.is_detached(provider) do
    {:reply, {:error, "No active provider"}, state}
  end

  def handle_call({:deactivate_skill, name}, _from, state) do
    result = GenServer.call(ProviderLifecycle.pid(state.provider), {:deactivate_skill, name})
    {:reply, result, state}
  end

  def handle_call(
        :list_skills,
        _from,
        %{provider: provider} = state
      )
      when ProviderLifecycle.is_detached(provider) do
    {:reply, {:error, "No active provider"}, state}
  end

  def handle_call(:list_skills, _from, state) do
    result = GenServer.call(ProviderLifecycle.pid(state.provider), :list_skills)
    {:reply, result, state}
  end

  def handle_call(
        :get_available_models,
        _from,
        %{provider: provider} = state
      )
      when ProviderLifecycle.is_detached(provider) do
    {:reply, {:error, :provider_not_ready}, state}
  end

  def handle_call(:get_available_models, _from, state) do
    result = state.provider.module.get_available_models(ProviderLifecycle.pid(state.provider))
    {:reply, result, state}
  end

  def handle_call(
        :get_commands,
        _from,
        %{provider: provider} = state
      )
      when ProviderLifecycle.is_detached(provider) do
    {:reply, {:error, :provider_not_ready}, state}
  end

  def handle_call(:get_commands, _from, state) do
    result = state.provider.module.get_commands(ProviderLifecycle.pid(state.provider))
    {:reply, result, state}
  end

  def handle_call(
        {:set_thinking_level, _level},
        _from,
        %{provider: provider} = state
      )
      when ProviderLifecycle.is_detached(provider) do
    {:reply, {:error, :provider_not_ready}, state}
  end

  def handle_call({:set_thinking_level, level}, _from, state) do
    result =
      dispatch_optional(state.provider.module, :set_thinking_level, [
        ProviderLifecycle.pid(state.provider),
        level
      ])

    {:reply, result, state}
  end

  def handle_call(
        :cycle_thinking_level,
        _from,
        %{provider: provider} = state
      )
      when ProviderLifecycle.is_detached(provider) do
    {:reply, {:error, :provider_not_ready}, state}
  end

  def handle_call(:cycle_thinking_level, _from, state) do
    result =
      dispatch_optional(state.provider.module, :cycle_thinking_level, [
        ProviderLifecycle.pid(state.provider)
      ])

    {:reply, result, state}
  end

  def handle_call(
        :cycle_model,
        _from,
        %{provider: provider} = state
      )
      when ProviderLifecycle.is_detached(provider) do
    {:reply, {:error, :provider_not_ready}, state}
  end

  def handle_call(:cycle_model, _from, state) do
    result =
      dispatch_optional(state.provider.module, :cycle_model, [
        ProviderLifecycle.pid(state.provider)
      ])

    {:reply, result, state}
  end

  def handle_call({:set_model, model}, _from, state) do
    {state, refresh_result} =
      state
      |> update_model_configuration(model)
      |> refresh_credentials_state_result()

    result =
      case {ProviderLifecycle.pid(state.provider), refresh_result} do
        {nil, {:error, reason}} ->
          {:error, reason}

        {nil, :ok} ->
          :ok

        {provider, _refresh_result} ->
          dispatch_optional(state.provider.module, :set_model, [provider, model])
      end

    {:reply, result, state}
  end

  def handle_call({:toggle_tool_collapse, index}, _from, state) do
    transcript =
      Transcript.update_at(state.transcript, index, fn
        {:tool_call, %ToolCall{} = tool_call} ->
          {:tool_call, ToolCall.toggle_collapsed(tool_call)}

        {:thinking, text, collapsed} ->
          {:thinking, text, !collapsed}

        other ->
          other
      end)

    state = %{state | transcript: transcript}
    state = notify_messages_changed(state)
    {:reply, :ok, state}
  end

  def handle_call(:toggle_all_tool_collapses, _from, state) do
    # If any tool call is collapsed, expand all; otherwise collapse all.
    any_collapsed =
      Enum.any?(Transcript.messages(state.transcript), fn
        {:tool_call, %ToolCall{collapsed: true}} -> true
        {:thinking, _, true} -> true
        _ -> false
      end)

    target = !any_collapsed

    transcript =
      Transcript.transform_messages(state.transcript, fn
        {:tool_call, %ToolCall{} = tool_call} ->
          {:tool_call, ToolCall.set_collapsed(tool_call, target)}

        {:thinking, text, _collapsed} ->
          {:thinking, text, target}

        other ->
          other
      end)

    state = %{state | transcript: transcript}
    state = notify_messages_changed(state)
    {:reply, :ok, state}
  end

  def handle_call({:branch_at, turn_index}, _from, state) do
    case Transcript.branch_at(state.transcript, turn_index, DateTime.utc_now()) do
      {:ok, transcript, branch} ->
        state = %{state | transcript: transcript}
        state = notify_messages_changed(state)

        {:reply, {:ok, "Branched at turn #{turn_index}. Branch saved as '#{branch.name}'."},
         state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:list_branches, _from, state) do
    {:reply, {:ok, Branch.list(Transcript.branches(state.transcript))}, state}
  end

  def handle_call({:switch_branch, branch_index}, _from, state) do
    case Transcript.switch_branch(state.transcript, branch_index) do
      {:ok, transcript} ->
        state = %{state | transcript: transcript}
        state = notify_messages_changed(state)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  @spec handle_cast(term(), state()) :: {:noreply, state()}
  def handle_cast({:add_system_message, text, level}, state) do
    state = append_system_message(state, text, level)
    state = notify_messages_changed(state)
    {:noreply, state}
  end

  def handle_cast(:refresh_credentials, state) do
    {:noreply, refresh_credentials_state(state)}
  end

  @impl GenServer
  @spec handle_info(term(), state()) :: {:noreply, state()} | {:stop, term(), state()}
  def handle_info(:start_provider, state) do
    {:noreply, refresh_credentials_state(state)}
  end

  def handle_info({:start_provider, token}, state) do
    case ProviderLifecycle.retry_due(state.provider, token) do
      {:start, lifecycle} ->
        state = install_provider_transition(state, lifecycle, [])
        {:noreply, refresh_credentials_state(state)}

      {:stale, _lifecycle} ->
        {:noreply, state}
    end
  end

  def handle_info({:agent_provider_event, event}, state) do
    state = handle_provider_event(event, state)
    {:noreply, state}
  end

  def handle_info(
        {:event_log_commit, _receipt, _event_type, {:persisted, _event_id}},
        state
      ) do
    {:noreply, state}
  end

  def handle_info(
        {:event_log_commit, receipt, event_type, {:error, {:persistence_failed, reason}}},
        state
      ) do
    Minga.Log.error(
      :agent,
      "[Agent.Session] event-log persistence failed for #{event_type}: #{inspect(reason)}"
    )

    failure = Failure.persistence(receipt, event_type, reason)
    notify_event_log_failure(state, failure)
    {:noreply, %{state | event_log_failure: failure}}
  end

  def handle_info({:event_log_failure, %Failure{} = failure}, state) do
    Minga.Log.error(
      :agent,
      "[Agent.Session] event-log admission failed for #{failure.event_type}: #{inspect(failure.reason)}"
    )

    notify_event_log_failure(state, failure)
    {:noreply, %{state | event_log_failure: failure}}
  end

  def handle_info(
        {:DOWN, _ref, :process, pid, reason},
        %{provider: %ProviderLifecycle{phase: {:running, pid, _lease, _retry}}} = state
      ) do
    {:noreply, handle_provider_death(state, reason)}
  end

  def handle_info(
        {:EXIT, pid, reason},
        %{provider: %ProviderLifecycle{phase: {:running, pid, _lease, _retry}}} = state
      ) do
    {:noreply, handle_provider_death(state, reason)}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    {:noreply, handle_subscriber_down(state, pid, ref, reason)}
  end

  def handle_info({:timeout, timer_ref, :idle_gc}, state) do
    handle_reclaim_timeout(state, timer_ref)
  end

  def handle_info(:save_session, %{persistence: %Persistence{timer: {token, _timer_ref}}} = state) do
    handle_info({:save_session, token}, state)
  end

  def handle_info(:save_session, state) do
    {persistence, timer_to_cancel} = Persistence.changed(state.persistence)

    cancel_runtime_timer(timer_to_cancel)

    token = make_ref()
    persistence = Persistence.scheduled(persistence, token, make_ref())
    handle_info({:save_session, token}, %{state | persistence: persistence})
  end

  def handle_info({:save_session, token}, state) do
    case Persistence.save_due(state.persistence, token) do
      :stale ->
        {:noreply, state}

      {:save, persistence} ->
        state = %{state | persistence: persistence}

        case save_to_disk(state) do
          :ok ->
            {:noreply, %{state | persistence: Persistence.saved(persistence)}}

          {:error, reason} ->
            Minga.Log.error(
              :agent,
              "[Agent.Session] failed to save session #{state.session_id} to disk: #{inspect(reason)}"
            )

            {:noreply, schedule_save_retry(state)}
        end
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @spec reply_to_continue(state(), TurnExecution.t() | nil) :: {:reply, term(), state()}
  defp reply_to_continue(state, proposed_execution) do
    result =
      if function_exported?(state.provider.module, :continue, 1) do
        state.provider.module.continue(ProviderLifecycle.pid(state.provider))
      else
        {:error, "Provider does not support continue"}
      end

    {:reply, result, finish_continue(state, proposed_execution, result)}
  end

  @spec finish_continue(state(), TurnExecution.t() | nil, term()) :: state()
  defp finish_continue(state, %TurnExecution{} = execution, :ok),
    do: %{state | turn_execution: execution}

  defp finish_continue(state, _proposed_execution, _result), do: state

  @spec abort_turn(state()) :: state()
  defp abort_turn(state) do
    source_execution = state.turn_execution
    execution = TurnExecution.abort(source_execution)

    state =
      state
      |> reject_execution_approval(source_execution)
      |> abort_provider()
      |> abort_active_tools(source_execution, false)
      |> append_system_message("Aborted", :info)
      |> notify_messages_changed()
      |> announce_turn_status(execution)

    %{state | turn_execution: execution}
  end

  @spec enter_plan_mode(state()) :: state()
  defp enter_plan_mode(state) do
    source_execution = state.turn_execution
    execution = TurnExecution.enter_plan(source_execution)

    state =
      state
      |> reject_execution_approval(source_execution)
      |> append_system_message(plan_mode_message(), :info)
      |> notify_messages_changed()
      |> broadcast({:status_changed, :plan})
      |> maybe_schedule_idle_gc(execution)

    %{state | turn_execution: execution}
  end

  @spec enter_exec_mode(state(), TurnExecution.t()) :: state()
  defp enter_exec_mode(state, execution) do
    state =
      state
      |> append_system_message(exec_mode_message(), :info)
      |> notify_messages_changed()
      |> announce_turn_status(execution)

    %{state | turn_execution: execution}
  end

  @spec queued_send_failed(state(), TurnExecution.t()) :: state()
  defp queued_send_failed(state, proposed_execution) do
    {:ok, execution} = TurnExecution.queued_send_failed(proposed_execution)
    state = announce_turn_status(state, execution)
    %{state | turn_execution: execution}
  end

  @spec complete_provider_turn(state(), Event.token_usage() | nil) :: state()
  defp complete_provider_turn(state, usage) do
    source_execution = state.turn_execution

    case TurnExecution.begin_completion(source_execution) do
      {:ok, completing} ->
        state
        |> reject_execution_approval(source_execution)
        |> notify(:complete, completion_notification(state))
        |> collapse_transcript_thinking()
        |> apply_turn_usage(usage)
        |> dispatch_stop()
        |> finish_provider_turn(completing)

      {:error, :invalid_phase} ->
        state
    end
  end

  @spec collapse_transcript_thinking(state()) :: state()
  defp collapse_transcript_thinking(state) do
    %{state | transcript: Transcript.collapse_thinking(state.transcript)}
  end

  @spec finish_provider_turn(state(), TurnExecution.t()) :: state()
  defp finish_provider_turn(state, completing) do
    case TurnExecution.finish_completion(completing) do
      {:idle, execution} ->
        state = announce_turn_status(state, execution)
        %{state | turn_execution: execution}

      {:send_next, contents, execution} ->
        send_queued_turn(state, contents, execution)
    end
  end

  @spec report_turn_error(state(), String.t()) :: state()
  defp report_turn_error(state, message) do
    execution = TurnExecution.report_error(state.turn_execution, message)

    state =
      state
      |> notify(:error, message)
      |> announce_turn_status(execution)
      |> append_error_message_once(message)
      |> notify_messages_changed()
      |> broadcast({:error, message})

    %{state | turn_execution: execution}
  end

  @spec mark_provider_failed(state(), String.t()) :: state()
  defp mark_provider_failed(state, message) do
    source_execution = state.turn_execution
    execution = TurnExecution.fail(source_execution, message)

    state =
      state
      |> reject_execution_approval(source_execution)
      |> abort_active_tools(source_execution, true)
      |> announce_turn_status(execution)

    %{state | turn_execution: execution}
  end

  @spec restore_turn_execution(state(), TurnExecution.t()) :: state()
  defp restore_turn_execution(state, execution) do
    source_execution = state.turn_execution

    state =
      if TurnExecution.active?(source_execution) do
        state
        |> reject_execution_approval(source_execution)
        |> abort_provider()
        |> abort_active_tools(source_execution, true)
      else
        state
      end

    %{state | turn_execution: execution}
  end

  @spec announce_turn_status(state(), TurnExecution.t()) :: state()
  defp announce_turn_status(state, execution) do
    case TurnExecution.mode(execution) do
      :exec ->
        state
        |> broadcast({:status_changed, TurnExecution.status(execution)})
        |> maybe_schedule_idle_gc(execution)

      :plan ->
        maybe_schedule_idle_gc(state, execution)
    end
  end

  @spec reject_execution_approval(state(), TurnExecution.t()) :: state()
  defp reject_execution_approval(state, execution) do
    reject_pending_approval(TurnExecution.pending_approval(execution))
    state
  end

  @spec send_approval_response(approval_resolution()) :: approval_resolution()
  defp send_approval_response({_state, approval, decision} = resolution) do
    send_approval_response(approval, decision)
    resolution
  end

  @spec send_approval_response(ToolApproval.t(), approval_decision()) :: :ok
  defp send_approval_response(approval, decision) do
    send(
      approval.reply_to,
      {:tool_approval_response, approval.tool_call_id, execution_decision(decision)}
    )

    :ok
  end

  @spec record_approval_resolution(approval_resolution()) :: approval_resolution()
  defp record_approval_resolution({state, approval, decision} = resolution) do
    record_critical_event(state, :approval_resolved, %{
      approval_id: approval.tool_call_id,
      tool_call_id: approval.tool_call_id,
      name: approval.name,
      decision: decision
    })

    resolution
  end

  @spec maybe_append_approval_rejection(approval_resolution()) :: state()
  defp maybe_append_approval_rejection({state, approval, :reject}) do
    append_system_message(
      state,
      "Denied #{approval.name}: the tool was refused and the agent was notified.",
      :info
    )
  end

  defp maybe_append_approval_rejection({state, _approval, _decision}), do: state

  @spec mark_tool_auto_approved(state(), Event.ToolApproval.t(), trust_scope()) :: state()
  defp mark_tool_auto_approved(state, event, scope) do
    transcript =
      Transcript.update_tool_call(state.transcript, event.tool_call_id, fn tool_call ->
        ToolCall.set_auto_approved_scope(tool_call, scope)
      end)

    %{state | transcript: transcript}
    |> broadcast({:tool_auto_approved, event.tool_call_id, event.name, scope})
    |> notify_messages_changed()
  end

  @spec append_tool_start(state(), Event.ToolStart.t(), trust_scope() | nil) :: state()
  defp append_tool_start(state, event, scope) do
    tool_call =
      event.tool_call_id
      |> ToolCall.new(event.name, event.args)
      |> ToolCall.set_auto_approved_scope(scope)

    state = append_msg(state, {:tool_call, tool_call})

    record_critical_event(state, :tool_call_started, %{
      tool_call_id: event.tool_call_id,
      name: event.name,
      args: event.args
    })

    state
    |> broadcast({:tool_started, event.name, event.args})
    |> notify_messages_changed()
  end

  @spec finish_tool(state(), Event.ToolEnd.t()) :: state()
  defp finish_tool(state, event) do
    transcript =
      Transcript.update_tool_call(state.transcript, event.tool_call_id, fn tool_call ->
        if event.is_error do
          ToolCall.error(tool_call, event.result)
        else
          ToolCall.complete(tool_call, event.result)
        end
      end)

    state = %{state | transcript: transcript}
    status = if event.is_error, do: :error, else: :done

    record_critical_event(state, :tool_call_finished, %{
      tool_call_id: event.tool_call_id,
      name: event.name,
      result: event.result,
      status: status
    })

    state
    |> broadcast({:tool_ended, event.name, event.result, status})
    |> notify_messages_changed()
  end

  @spec append_steering_messages(state(), [TurnExecution.content()]) :: state()
  defp append_steering_messages(state, []), do: state

  defp append_steering_messages(state, contents) do
    messages =
      Enum.map(contents, fn content ->
        {user_message, _send_content} = build_user_message(content)
        user_message
      end)

    Enum.each(messages, &record_user_message_event(state, &1))

    state
    |> append_msgs(messages)
    |> notify_messages_changed()
  end

  @spec abort_provider(state()) :: state()
  defp abort_provider(state) do
    case ProviderLifecycle.pid(state.provider) do
      pid when is_pid(pid) -> state.provider.module.abort(pid)
      nil -> :ok
    end

    state
  end

  @spec abort_active_tools(state(), TurnExecution.t(), boolean()) :: state()
  defp abort_active_tools(state, execution, notify?) do
    case TurnExecution.active_tools(execution) do
      [] ->
        state

      [_tool | _rest] ->
        transcript =
          Transcript.transform_messages(state.transcript, fn
            {:tool_call, %ToolCall{} = tool_call} -> {:tool_call, ToolCall.abort(tool_call)}
            other -> other
          end)

        state = %{state | transcript: transcript}
        if notify?, do: notify_messages_changed(state), else: state
    end
  end

  @spec apply_turn_usage(state(), Event.token_usage() | nil) :: state()
  defp apply_turn_usage(state, nil), do: notify_messages_changed(state)

  defp apply_turn_usage(state, usage) do
    log_turn_usage(usage, state)

    state
    |> Map.update!(:transcript, &Transcript.add_usage(&1, usage))
    |> append_msg(Message.usage(usage))
    |> notify_messages_changed()
  end

  @spec send_queued_turn(state(), [TurnExecution.content(), ...], TurnExecution.t()) :: state()
  defp send_queued_turn(state, contents, execution) do
    combined = combine_queue_entries_to_text(contents)
    {user_message, send_content} = build_user_message(combined)

    state =
      state
      |> append_msg(user_message)
      |> record_user_message_event(user_message)
      |> notify_messages_changed()

    case state.provider.module.send_prompt(ProviderLifecycle.pid(state.provider), send_content) do
      :ok -> %{state | turn_execution: execution}
      {:error, _reason} -> queued_send_failed(state, execution)
    end
  end

  @spec handle_approval_response(approval_decision(), state()) ::
          {:reply, :ok | {:error, :no_pending_approval}, state()}
  defp handle_approval_response(decision, state),
    do: handle_approval_response(nil, decision, state)

  @spec handle_approval_response(String.t() | nil, approval_decision(), state()) ::
          {:reply, :ok | {:error, :approval_not_found | :no_pending_approval}, state()}
  defp handle_approval_response(approval_id, decision, state) do
    case TurnExecution.resolve_approval(state.turn_execution, approval_id, decision) do
      {:ok, approval, execution} ->
        state =
          {state, approval, decision}
          |> send_approval_response()
          |> record_approval_resolution()
          |> maybe_append_approval_rejection()
          |> notify_messages_changed()
          |> broadcast({:approval_resolved, decision})

        {:reply, :ok, %{state | turn_execution: execution}}

      {:error, :approval_not_found} ->
        {:reply, {:error, :approval_not_found}, state}

      {:error, :no_pending_approval} ->
        Minga.Log.warning(:agent, "[Session] respond_to_approval called with no pending approval")
        {:reply, {:error, :no_pending_approval}, state}
    end
  end

  @spec handle_prompt(
          String.t() | [ReqLLM.Message.ContentPart.t()],
          TurnExecution.prompt_kind(),
          state()
        ) :: {:reply, :ok | {:queued, TurnExecution.prompt_kind()} | {:error, term()}, state()}
  defp handle_prompt(_content, _kind, %{credentials_configured: false} = state) do
    # No usable provider yet. Refuse locally so callers can preserve the draft instead of clearing it.
    {:reply, {:error, :credentials_not_configured}, state}
  end

  defp handle_prompt(
         content,
         kind,
         %{provider: provider} = state
       )
       when ProviderLifecycle.is_detached(provider) do
    state = refresh_credentials_state(state)

    case ProviderLifecycle.pid(state.provider) do
      nil -> {:reply, {:error, :provider_not_ready}, state}
      _ -> handle_prompt(content, kind, state)
    end
  end

  defp handle_prompt(content, kind, state) do
    case TurnExecution.admit_prompt(state.turn_execution, kind, content) do
      {:queued, execution} ->
        state = broadcast(state, {:prompt_queued, content, kind})
        {:reply, {:queued, kind}, %{state | turn_execution: execution}}

      {:send_now, execution} ->
        send_new_turn(content, state, execution)
    end
  end

  @spec send_new_turn(
          String.t() | [ReqLLM.Message.ContentPart.t()],
          state(),
          TurnExecution.t()
        ) :: {:reply, :ok | {:error, term()}, state()}
  defp send_new_turn(content, state, execution) do
    case dispatch_user_prompt_submit(state, content) do
      :ok ->
        {user_message, send_content} = build_user_message(content)

        state =
          state
          |> append_msg(user_message)
          |> record_user_message_event(user_message)
          |> notify_messages_changed()

        case state.provider.module.send_prompt(
               ProviderLifecycle.pid(state.provider),
               send_content
             ) do
          :ok ->
            {:reply, :ok, %{state | turn_execution: execution}}

          {:error, _reason} = error ->
            {:reply, error, announce_turn_status(state, state.turn_execution)}
        end

      {:error, %HookResult{} = result} ->
        {:reply, {:error, {:hook_veto, HookResult.message(result)}}, state}
    end
  end

  # ── Event handling ──────────────────────────────────────────────────────────

  @spec handle_provider_event(Event.t(), state()) :: state()
  defp handle_provider_event(%Event.AgentStart{}, state) do
    case TurnExecution.provider_started(state.turn_execution) do
      {:ok, execution} ->
        state = announce_turn_status(state, execution)
        %{state | turn_execution: execution}

      {:error, :invalid_phase} ->
        state
    end
  end

  defp handle_provider_event(%Event.AgentEnd{usage: usage}, state),
    do: complete_provider_turn(state, usage)

  defp handle_provider_event(%Event.TextDelta{delta: delta}, state) do
    state
    |> Map.update!(:transcript, &Transcript.append_stream_tail(&1, :assistant, [delta]))
    |> broadcast({:text_delta, delta})
  end

  defp handle_provider_event(%Event.ThinkingDelta{delta: delta}, state) do
    state
    |> Map.update!(:transcript, &Transcript.append_stream_tail(&1, :thinking, [delta]))
    |> broadcast({:thinking_delta, delta})
  end

  defp handle_provider_event(%Event.ToolStart{} = event, state) do
    case TurnExecution.tool_started(state.turn_execution, event) do
      {:ok, scope, execution} ->
        state =
          state
          |> announce_turn_status(execution)
          |> append_tool_start(event, scope)

        %{state | turn_execution: execution}

      {:error, _reason} ->
        state
    end
  end

  defp handle_provider_event(%Event.ToolFileChanged{} = event, state) do
    tool_name =
      case TurnExecution.tool_name(state.turn_execution, event.tool_call_id) do
        {:ok, name} -> name
        {:error, :tool_not_active} -> "unknown"
      end

    handle_tool_file_changed(event, tool_name, state)
  end

  defp handle_provider_event(%Event.SystemMessage{} = event, state) do
    state
    |> append_system_message(event.message, event.level)
    |> notify_messages_changed()
  end

  defp handle_provider_event(%Event.TodoPlan{todos: todos}, state) do
    broadcast(state, {:todo_plan_updated, todos})
  end

  defp handle_provider_event(%Event.ToolApproval{} = event, state) do
    case TurnExecution.trusted_scope(state.turn_execution, event) do
      nil -> request_tool_approval(event, state)
      scope -> auto_approve_tool(event, state, scope)
    end
  end

  defp handle_provider_event(%Event.ToolUpdate{} = event, state) do
    handle_tool_update(event, state)
  end

  defp handle_provider_event(%Event.ToolEnd{} = event, state) do
    case TurnExecution.tool_completed(state.turn_execution, event) do
      {:ok, execution} ->
        state = finish_tool(state, event)
        %{state | turn_execution: execution}

      {:error, :tool_not_active} ->
        state
    end
  end

  defp handle_provider_event(%Event.ContextUsage{} = event, state) do
    broadcast(state, {:context_usage, event.estimated_tokens, event.context_limit})
  end

  defp handle_provider_event(%Event.TurnLimitReached{current: current, limit: limit}, state) do
    broadcast(state, {:turn_limit_reached, current, limit})
  end

  defp handle_provider_event(%Event.Error{} = event, state) do
    report_turn_error(state, humanize_error(event, state))
  end

  @spec handle_tool_file_changed(Event.ToolFileChanged.t(), String.t(), state()) :: state()
  defp handle_tool_file_changed(event, tool_name, state) do
    state
    |> broadcast(
      {:file_changed, event.path, event.before_content, event.after_content, event.tool_call_id,
       tool_name}
    )
    |> record_tool_file_preview(event)
    |> notify_messages_changed()
  end

  @spec handle_tool_update(Event.ToolUpdate.t(), state()) :: state()
  defp handle_tool_update(event, state) do
    state
    |> Map.update!(:transcript, fn transcript ->
      Transcript.update_tool_call(transcript, event.tool_call_id, fn tool_call ->
        ToolCall.update_partial(tool_call, event.partial_result)
      end)
    end)
    |> broadcast({:tool_update, event.tool_call_id, event.name, event.partial_result})
  end

  @spec append_error_message_once(state(), String.t()) :: state()
  defp append_error_message_once(state, message) do
    case Transcript.last_message(state.transcript) do
      {:system, ^message, :error} -> state
      _other -> append_system_message(state, message, :error)
    end
  end

  @spec request_tool_approval(Event.ToolApproval.t(), state()) :: state()
  defp request_tool_approval(event, %{tool_approval_policy: {:auto_approve, scope}} = state) do
    auto_approve_tool(event, state, scope)
  end

  defp request_tool_approval(event, %{tool_approval_policy: {:reject, message}} = state) do
    send(event.reply_to, {:tool_approval_response, event.tool_call_id, {:reject, message}})
    broadcast(state, {:approval_rejected, event.tool_call_id, event.name, message})
  end

  defp request_tool_approval(event, state) do
    approval =
      ToolApproval.new(
        tool_call_id: event.tool_call_id,
        name: event.name,
        args: event.args,
        reply_to: event.reply_to
      )

    case TurnExecution.request_approval(state.turn_execution, approval) do
      {:accepted, execution} ->
        state =
          state
          |> notify(:approval, "Approval needed: #{approval.name}")
          |> broadcast({:approval_pending, ToolApproval.public(approval)})

        %{state | turn_execution: execution}

      :rejected ->
        reject_pending_approval(approval)
        state
    end
  end

  @spec auto_approve_tool(Event.ToolApproval.t(), state(), trust_scope()) :: state()
  defp auto_approve_tool(event, state, scope) do
    case TurnExecution.auto_approve(state.turn_execution, event, scope) do
      {:approved, approval, execution} ->
        send_approval_response(approval, :approve)
        state = mark_tool_auto_approved(state, event, scope)
        %{state | turn_execution: execution}

      {:rejected, approval} ->
        reject_pending_approval(approval)
        state
    end
  end

  @spec completion_notification(state()) :: String.t()
  defp completion_notification(%{background_subagent: true, session_id: session_id}) do
    "Sub-agent #{session_id} finished"
  end

  defp completion_notification(_state), do: "Agent finished"

  @spec notify(state(), atom(), String.t()) :: state()
  defp notify(%{notifier: {module, arg}} = state, trigger, message) when is_atom(module) do
    dispatch_notification(state, trigger, message)
    module.notify(trigger, message, arg)
    state
  end

  defp notify(%{notifier: module} = state, trigger, message) when is_atom(module) do
    dispatch_notification(state, trigger, message)
    module.notify(trigger, message)
    state
  end

  # ── Message list helpers ────────────────────────────────────────────────────

  # Appends a message and assigns it a new stable ID.
  @spec append_msg(state(), Message.t()) :: state()
  defp append_msg(state, message) do
    %{state | transcript: Transcript.append(state.transcript, message)}
  end

  # Appends multiple messages, assigning each a new stable ID.
  @spec append_msgs(state(), [Message.t()]) :: state()
  defp append_msgs(state, messages) do
    %{state | transcript: Transcript.append_many(state.transcript, messages)}
  end

  @spec append_system_message(state(), String.t(), Message.system_level()) :: state()
  defp append_system_message(state, text, level) do
    record_critical_event(state, :system_message, %{message: text, level: level})

    msg = Message.system(text, level)
    append_msg(state, msg)
  end

  @spec execution_decision(approval_decision()) :: :approve | :reject
  defp execution_decision(:reject), do: :reject
  defp execution_decision(_decision), do: :approve

  @spec public_pending_approval(MingaAgent.ToolApproval.t() | nil) :: map() | nil
  defp public_pending_approval(nil), do: nil

  defp public_pending_approval(%MingaAgent.ToolApproval{} = approval),
    do: MingaAgent.ToolApproval.public(approval)

  @spec record_tool_file_preview(state(), Event.ToolFileChanged.t()) :: state()
  defp record_tool_file_preview(state, %Event.ToolFileChanged{} = event) do
    preview =
      ToolApproval.build_file_diff_preview(event.path, event.before_content, event.after_content)

    transcript =
      Transcript.update_tool_call(state.transcript, event.tool_call_id, fn tool_call ->
        ToolCall.set_preview(tool_call, preview)
      end)

    %{state | transcript: transcript}
  end

  # ── Status management ──────────────────────────────────────────────────────

  @spec reject_pending_approval(pending_approval() | nil) :: :ok
  defp reject_pending_approval(nil), do: :ok

  defp reject_pending_approval(%{tool_call_id: tool_call_id, reply_to: reply_to}) do
    send(reply_to, {:tool_approval_response, tool_call_id, :reject})
    :ok
  end

  @spec plan_mode_message() :: String.t()
  defp plan_mode_message do
    "Plan mode enabled. Destructive tools are blocked before execution. Read-only and search tools still work. Use /exec when you are ready to make changes."
  end

  @spec exec_mode_message() :: String.t()
  defp exec_mode_message do
    "Execution mode enabled. Destructive tools can run again after normal approval checks. Use /plan to return to planning."
  end

  # ── Subscriber lifecycle ──────────────────────────────────────────────────

  @spec reply_to_subscribe(state(), pid(), term()) ::
          {:reply, :ok | {:error, :invalid_role}, state()}
  defp reply_to_subscribe(state, pid, role) do
    case SubscriberLifecycle.prepare_subscribe(state.subscriber_lifecycle, pid, role) do
      {:monitor, preparation} ->
        monitor_subscriber(state, pid, preparation)

      {:already_attached, lifecycle} ->
        notify_subscriber_connected(pid, state)
        {:reply, :ok, %{state | subscriber_lifecycle: lifecycle}}

      {:error, :invalid_role} ->
        {:reply, {:error, :invalid_role}, state}
    end
  end

  @spec monitor_subscriber(state(), pid(), SubscriberLifecycle.subscription_preparation()) ::
          {:reply, :ok, state()}
  defp monitor_subscriber(state, pid, preparation) do
    monitor_ref = Process.monitor(pid)

    case SubscriberLifecycle.complete_subscribe(
           state.subscriber_lifecycle,
           preparation,
           monitor_ref
         ) do
      {:ok, lifecycle, subscription_change, timer_ref} ->
        cancel_reclaim_timer(timer_ref)

        state =
          state
          |> Map.put(:subscriber_lifecycle, lifecycle)
          |> announce_subscription_change(pid, subscription_change)

        notify_subscriber_connected(pid, state)
        {:reply, :ok, state}

      {:error, reason} ->
        Process.demonitor(monitor_ref, [:flush])
        raise "subscriber monitor installation failed: #{inspect(reason)}"
    end
  end

  @spec announce_subscription_change(
          state(),
          pid(),
          SubscriberLifecycle.subscription_change()
        ) :: state()
  defp announce_subscription_change(state, pid, :driver_changed),
    do: broadcast(state, {:driver_changed, pid})

  defp announce_subscription_change(state, _pid, :driver_initialized), do: state

  defp announce_subscription_change(state, _pid, :viewer_attached), do: state

  @spec notify_subscriber_connected(pid(), state()) :: :ok
  defp notify_subscriber_connected(pid, state) do
    send(pid, {:agent_event, self(), {:credentials_status, state.credentials_configured}})
    notify_retained_event_log_failure(pid, state.event_log_failure)
  end

  @spec reply_to_claim_driver(state(), pid()) ::
          {:reply, :ok | {:error, :driver_taken | :not_subscribed}, state()}
  defp reply_to_claim_driver(state, pid) do
    case SubscriberLifecycle.claim_driver(state.subscriber_lifecycle, pid) do
      {:changed, lifecycle} ->
        state = %{state | subscriber_lifecycle: lifecycle}
        {:reply, :ok, broadcast(state, {:driver_changed, pid})}

      :unchanged ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @spec detach_subscriber(state(), pid(), term()) :: state()
  defp detach_subscriber(state, pid, reason) do
    case SubscriberLifecycle.detach(state.subscriber_lifecycle, pid) do
      {:removed, lifecycle, %SubscriberAttachment{} = attachment} ->
        Process.demonitor(attachment.monitor_ref, [:flush])
        state = %{state | subscriber_lifecycle: lifecycle}
        record_user_disconnected(state, pid, attachment.role, reason)
        maybe_schedule_idle_gc(state)

      :unchanged ->
        state
    end
  end

  @spec handle_subscriber_down(state(), pid(), reference(), term()) :: state()
  defp handle_subscriber_down(state, pid, monitor_ref, reason) do
    case SubscriberLifecycle.subscriber_down(
           state.subscriber_lifecycle,
           pid,
           monitor_ref
         ) do
      {:removed, lifecycle, %SubscriberAttachment{} = attachment} ->
        state = %{state | subscriber_lifecycle: lifecycle}
        record_user_disconnected(state, pid, attachment.role, reason)
        maybe_schedule_idle_gc(state)

      {:error, :stale_monitor} ->
        state
    end
  end

  @spec record_user_disconnected(state(), pid(), attachment_role(), term()) ::
          EventLog.admission_result()
  defp record_user_disconnected(state, pid, role, reason) do
    record_critical_event(state, :user_disconnected, %{
      pid: inspect(pid),
      role: role,
      reason: inspect(reason)
    })
  end

  @spec maybe_schedule_idle_gc(state()) :: state()
  defp maybe_schedule_idle_gc(state),
    do: maybe_schedule_idle_gc(state, state.turn_execution)

  @spec maybe_schedule_idle_gc(state(), TurnExecution.t()) :: state()
  defp maybe_schedule_idle_gc(state, execution) do
    enabled? = state.idle_gc_timeout_ms > 0
    turn_reclaimable? = TurnExecution.reclaimable?(execution)

    case SubscriberLifecycle.reconcile_reclaim(
           state.subscriber_lifecycle,
           enabled?,
           turn_reclaimable?
         ) do
      {:start_timer, preparation} ->
        start_reclaim_timer(state, preparation)

      {:cancel_timer, timer_ref, lifecycle} ->
        cancel_reclaim_timer(timer_ref)
        %{state | subscriber_lifecycle: lifecycle}

      :unchanged ->
        state
    end
  end

  @spec start_reclaim_timer(state(), SubscriberLifecycle.reclaim_preparation()) :: state()
  defp start_reclaim_timer(state, preparation) do
    timer_ref = :erlang.start_timer(state.idle_gc_timeout_ms, self(), :idle_gc)

    case SubscriberLifecycle.complete_reclaim_schedule(
           state.subscriber_lifecycle,
           preparation,
           timer_ref
         ) do
      {:ok, lifecycle} ->
        %{state | subscriber_lifecycle: lifecycle}

      {:error, reason} ->
        Process.cancel_timer(timer_ref)
        raise "subscriber reclaim timer installation failed: #{inspect(reason)}"
    end
  end

  @spec handle_reclaim_timeout(state(), reference()) ::
          {:noreply, state()} | {:stop, :normal, state()}
  defp handle_reclaim_timeout(state, timer_ref) do
    turn_reclaimable? = TurnExecution.reclaimable?(state.turn_execution)

    case SubscriberLifecycle.reclaim_timeout(
           state.subscriber_lifecycle,
           timer_ref,
           turn_reclaimable?
         ) do
      {:reclaim, lifecycle} ->
        reclaim_idle_session(%{state | subscriber_lifecycle: lifecycle})

      {:keep, lifecycle} ->
        state = %{state | subscriber_lifecycle: lifecycle}
        {:noreply, maybe_schedule_idle_gc(state)}

      {:error, :stale_timer} ->
        {:noreply, state}
    end
  end

  @spec reclaim_idle_session(state()) :: {:noreply, state()} | {:stop, :normal, state()}
  defp reclaim_idle_session(state) do
    Minga.Log.info(
      :agent,
      "[Agent.Session] reclaiming idle detached session #{state.session_id}"
    )

    case save_to_disk(state) do
      :ok ->
        {:stop, :normal, state}

      {:error, reason} ->
        Minga.Log.error(
          :agent,
          "[Agent.Session] failed to reclaim idle detached session #{state.session_id}: #{inspect(reason)}"
        )

        {:noreply, maybe_schedule_idle_gc(state)}
    end
  end

  @spec cancel_reclaim_timer(reference() | nil) :: :ok
  defp cancel_reclaim_timer(nil), do: :ok

  defp cancel_reclaim_timer(timer_ref) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  @spec idle_gc_timeout_ms() :: non_neg_integer()
  defp idle_gc_timeout_ms do
    Options.get(:agent_session_idle_timeout_ms)
  end

  @spec driver_allowed?(state(), pid()) :: boolean()
  defp driver_allowed?(state, pid),
    do: SubscriberLifecycle.driver?(state.subscriber_lifecycle, pid)

  # ── Broadcasting ────────────────────────────────────────────────────────────

  @spec broadcast(state(), term()) :: state()
  defp broadcast(state, event) do
    record_broadcast_event(state, event)
    session_pid = self()

    Enum.each(SubscriberLifecycle.subscribers(state.subscriber_lifecycle), fn pid ->
      send(pid, {:agent_event, session_pid, event})
    end)

    state
  end

  @spec notify_event_log_failure(state(), Failure.t()) :: :ok
  defp notify_event_log_failure(state, failure) do
    session_pid = self()

    Enum.each(SubscriberLifecycle.subscribers(state.subscriber_lifecycle), fn pid ->
      send(pid, {:agent_event, session_pid, failure})
    end)
  end

  @spec notify_retained_event_log_failure(pid(), event_log_failure() | nil) :: :ok
  defp notify_retained_event_log_failure(_pid, nil), do: :ok

  defp notify_retained_event_log_failure(pid, failure) do
    send(pid, {:agent_event, self(), Failure.retained(failure)})
    :ok
  end

  @spec maybe_mark_interrupted_work(state(), boolean()) :: :ok
  defp maybe_mark_interrupted_work(_state, false), do: :ok

  defp maybe_mark_interrupted_work(state, true) do
    Minga.Telemetry.span(
      [:minga, :agent, :mark_interrupted_work],
      %{session_id: state.session_id},
      fn ->
        mark_interrupted_work(state)
      end
    )
  end

  @spec mark_interrupted_work(state()) :: :ok
  defp mark_interrupted_work(state) do
    case EventLog.open_read_connection() do
      {:ok, db} ->
        try do
          case all_event_log_events(db, state.session_id) do
            {:ok, events} ->
              record_interrupted_work(state, events)

            {:error, reason} ->
              log_interrupted_work_failure(state.session_id, reason)
          end
        after
          MingaAgent.EventLog.Store.close(db)
        end

      {:error, :database_not_found} ->
        :ok

      {:error, reason} ->
        log_interrupted_work_failure(state.session_id, reason)
    end
  end

  @spec log_interrupted_work_failure(String.t(), term()) :: :ok
  defp log_interrupted_work_failure(session_id, reason) do
    Minga.Log.warning(
      :agent,
      "[Session] mark_interrupted_work failed for #{session_id}: #{inspect(reason)}"
    )
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
          all_event_log_events(
            db,
            session_id,
            Enum.at(events, -1).id,
            Enum.reverse(events) ++ acc
          )
      end
    end
  end

  @spec record_interrupted_work(state(), [EventLog.EventRecord.t()]) :: :ok
  defp record_interrupted_work(state, events) do
    tool_ids = open_tool_call_ids(events)
    approval_ids = open_approval_ids(events)

    Enum.each(tool_ids, fn tool_call_id ->
      record_critical_event(state, :tool_call_interrupted, %{tool_call_id: tool_call_id})
    end)

    Enum.each(approval_ids, fn approval_id ->
      record_critical_event(state, :approval_interrupted, %{
        approval_id: approval_id,
        tool_call_id: approval_id
      })
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

  @spec record_broadcast_event(state(), term()) ::
          EventLog.admission_result() | EventLog.best_effort_admission_result() | :ok
  defp record_broadcast_event(state, event) do
    case event_log_entry(event) do
      {event_type, payload} ->
        record_event_log_entry(state, event_type, payload)

      nil ->
        :ok
    end
  end

  @spec record_event_log_entry(state(), EventLog.EventRecord.event_type(), map()) ::
          EventLog.admission_result() | EventLog.best_effort_admission_result()
  defp record_event_log_entry(state, :assistant_delta, payload) do
    EventLog.record_best_effort(
      state.session_id,
      :assistant_delta,
      payload,
      state.event_log_server
    )
  end

  defp record_event_log_entry(state, :thinking_delta, payload) do
    EventLog.record_best_effort(
      state.session_id,
      :thinking_delta,
      payload,
      state.event_log_server
    )
  end

  defp record_event_log_entry(state, event_type, payload) do
    record_critical_event(state, event_type, payload)
  end

  @spec record_critical_event(state(), EventLog.EventRecord.event_type(), map()) ::
          EventLog.admission_result()
  defp record_critical_event(state, event_type, payload) do
    result = EventLog.record(state.session_id, event_type, payload, state.event_log_server)
    report_admission_failure(state, event_type, result)
    result
  end

  @spec report_admission_failure(
          state(),
          EventLog.EventRecord.event_type(),
          EventLog.admission_result()
        ) :: :ok
  defp report_admission_failure(_state, _event_type, {:queued, _receipt}), do: :ok

  defp report_admission_failure(_state, event_type, {:error, reason}) do
    send(self(), {:event_log_failure, Failure.admission(event_type, reason)})
    :ok
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

  defp event_log_entry({:todo_plan_updated, todos}),
    do: {:todo_plan_updated, %{todos: todo_items_payload(todos)}}

  defp event_log_entry({:approval_resolved, _decision}), do: nil

  defp event_log_entry({:system_message, _message, _level}), do: nil

  defp event_log_entry({:status_changed, :idle}), do: {:waiting_for_input, %{status: :idle}}
  defp event_log_entry({:status_changed, status}), do: {:status_changed, %{status: status}}

  defp event_log_entry({:prompt_queued, content, queue}),
    do: {:prompt_queued, %{content: content, queue: queue}}

  defp event_log_entry(:messages_changed), do: nil
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

  @spec todo_items_payload(term()) :: [map()]
  defp todo_items_payload(todos) when is_list(todos) do
    Enum.map(todos, &todo_item_payload/1)
  end

  defp todo_items_payload(_todos), do: []

  @spec todo_item_payload(map()) :: map()
  defp todo_item_payload(todo) do
    %{
      "id" => todo_value(todo, :id),
      "description" => todo_value(todo, :description),
      "status" => todo_status_payload(todo_value(todo, :status))
    }
  end

  @spec todo_value(map(), atom()) :: term()
  defp todo_value(todo, key) do
    Map.get(todo, key) || Map.get(todo, Atom.to_string(key))
  end

  @spec todo_status_payload(term()) :: String.t()
  defp todo_status_payload(status) when is_binary(status), do: status
  defp todo_status_payload(status) when is_atom(status), do: Atom.to_string(status)
  defp todo_status_payload(status), do: to_string(status)

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

  @spec record_user_message_event(state(), Message.t()) :: state()
  defp record_user_message_event(state, {:user, text}) do
    record_critical_event(state, :user_message, %{text: text, attachments: []})
    state
  end

  defp record_user_message_event(state, {:user, text, attachments}) do
    record_critical_event(state, :user_message, %{text: text, attachments: attachments})
    state
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
    state
    |> Map.update!(:transcript, &Transcript.touch(&1, DateTime.utc_now()))
    |> broadcast(:messages_changed)
    |> schedule_save()
  end

  @spec seed_provider_messages(state(), [Message.t()]) :: state()
  defp seed_provider_messages(
         %{
           provider: %ProviderLifecycle{
             module: module,
             phase: {:running, provider, _lease, _retry}
           }
         } = state,
         messages
       )
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

  @spec acquire_provider_lease!(
          Minga.Extension.ContributionCleanup.contribution_source(),
          module(),
          String.t()
        ) ::
          CodeLease.t() | nil
  defp acquire_provider_lease!({:bundle, _name} = source, module, provider_id) do
    acquire_source_provider_lease!(source, module, provider_id)
  end

  defp acquire_provider_lease!({:extension, _name} = source, module, provider_id) do
    acquire_source_provider_lease!(source, module, provider_id)
  end

  defp acquire_provider_lease!(_source, _module, _provider_id), do: nil

  @spec acquire_source_provider_lease!(
          Minga.Extension.ContributionCleanup.contribution_source(),
          module(),
          String.t()
        ) :: CodeLease.t()
  defp acquire_source_provider_lease!(source, module, provider_id) do
    with :ok <- validate_source_owned_provider(source, module, provider_id),
         {:ok, lease} <- ensure_provider_lease(source, module, nil) do
      lease
    else
      {:error, reason} ->
        raise "failed to lease source-owned provider #{inspect(module)}: #{inspect(reason)}"
    end
  end

  @spec ensure_provider_lease(
          Minga.Extension.ContributionCleanup.contribution_source(),
          module(),
          CodeLease.t() | nil
        ) :: {:ok, CodeLease.t()} | {:error, term()}
  defp ensure_provider_lease(_source, _module, %CodeLease{} = lease), do: {:ok, lease}

  defp ensure_provider_lease({:bundle, _name} = source, module, nil) do
    CodeLease.lease(source, module, :provider, owner: self())
  end

  defp ensure_provider_lease({:extension, _name} = source, module, nil) do
    CodeLease.lease(source, module, :provider, owner: self())
  end

  @spec start_provider(state()) :: {:ok, pid(), state()} | {:error, term(), state()}
  defp start_provider(%{provider: %ProviderLifecycle{source: {:bundle, _name}}} = state) do
    start_source_owned_provider(state)
  end

  defp start_provider(%{provider: %ProviderLifecycle{source: {:extension, _name}}} = state) do
    start_source_owned_provider(state)
  end

  defp start_provider(state), do: start_provider_process(state)

  @spec start_source_owned_provider(state()) :: {:ok, pid(), state()} | {:error, term(), state()}
  defp start_source_owned_provider(state) do
    with :ok <-
           validate_source_owned_provider(
             state.provider.source,
             state.provider.module,
             state.provider.id
           ),
         {:ok, lease} <-
           ensure_source_provider_lease(
             state.provider.source,
             state.provider.module,
             ProviderLifecycle.lease(state.provider)
           ) do
      {:ok, lifecycle} = ProviderLifecycle.install_lease(state.provider, lease)
      start_provider_process(%{state | provider: lifecycle})
    else
      {:error, {:provider_lease_unavailable, _reason} = reason} -> {:error, reason, state}
      {:error, reason} -> {:error, {:provider_unavailable, reason}, state}
    end
  end

  @spec ensure_source_provider_lease(
          Minga.Extension.ContributionCleanup.contribution_source(),
          module(),
          CodeLease.t() | nil
        ) :: {:ok, CodeLease.t()} | {:error, {:provider_lease_unavailable, term()}}
  defp ensure_source_provider_lease(source, module, lease) do
    case ensure_provider_lease(source, module, lease) do
      {:ok, lease} -> {:ok, lease}
      {:error, reason} -> {:error, {:provider_lease_unavailable, reason}}
    end
  end

  @spec validate_source_owned_provider(
          Minga.Extension.ContributionCleanup.contribution_source(),
          module(),
          String.t()
        ) :: :ok | {:error, term()}
  defp validate_source_owned_provider(source, module, provider_id) do
    with {:ok, id} <- validate_provider_id(provider_id),
         {:ok, entry} <- lookup_provider_registry_entry(id) do
      validate_provider_registry_entry(entry.spec, source, module)
    end
  catch
    :exit, reason -> {:error, {:provider_registry_unavailable, provider_id, reason}}
  end

  @spec validate_provider_id(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp validate_provider_id(provider_id) when is_binary(provider_id) do
    if String.trim(provider_id) == "" do
      {:error, {:missing_provider_id, provider_id}}
    else
      {:ok, provider_id}
    end
  end

  @spec lookup_provider_registry_entry(String.t()) ::
          {:ok, MingaAgent.ProviderRegistry.Entry.t()} | {:error, term()}
  defp lookup_provider_registry_entry(id) do
    case ProviderRegistry.lookup(id) do
      {:ok, entry} -> {:ok, entry}
      {:error, :disabled} -> {:error, {:provider_disabled, id}}
      {:error, :not_found} -> {:error, {:provider_not_found, id}}
    end
  end

  @spec validate_provider_registry_entry(
          MingaAgent.Provider.Spec.t(),
          Minga.Extension.ContributionCleanup.contribution_source(),
          module()
        ) :: :ok | {:error, term()}
  defp validate_provider_registry_entry(%{source: source, module: module}, source, module),
    do: :ok

  defp validate_provider_registry_entry(spec, source, module) do
    {:error,
     {:provider_registry_mismatch,
      %{
        expected_source: source,
        expected_module: module,
        source: spec.source,
        module: spec.module
      }}}
  end

  @spec start_provider_process(state()) :: {:ok, pid(), state()} | {:error, term(), state()}
  defp start_provider_process(state) do
    case state.provider.module.start_link(state.provider.opts) do
      {:ok, pid} -> {:ok, pid, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @spec release_provider_lease(CodeLease.t() | nil) :: :ok
  defp release_provider_lease(nil), do: :ok

  defp release_provider_lease(lease) do
    CodeLease.release(lease)
    :ok
  end

  @spec initial_system_message(String.t(), String.t() | nil) :: String.t()
  defp initial_system_message(timestamp, nil), do: "Session started · #{timestamp}"
  defp initial_system_message(timestamp, notice), do: "Session started · #{timestamp} · #{notice}"

  @spec build_subagent_context(state()) :: subagent_context()
  defp build_subagent_context(state) do
    provider_state = provider_state(state)

    SubagentContext.new(
      provider_module: state.provider.module,
      provider_name: provider_name(provider_state, state),
      provider_id: state.provider.id,
      provider_source: state.provider.source,
      model: provider_model(provider_state, state),
      thinking_level: provider_thinking_level(provider_state),
      active_skill_names: provider_active_skill_names(provider_state),
      project_root: provider_project_root(provider_state, state)
    )
  end

  @spec provider_state(state()) :: map()
  defp provider_state(%{provider: provider}) when ProviderLifecycle.is_detached(provider),
    do: %{}

  defp provider_state(state) do
    case state.provider.module.get_state(ProviderLifecycle.pid(state.provider)) do
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
  defp provider_name(
         _provider_state,
         %{
           provider: %ProviderLifecycle{
             module: MingaAgent.Providers.Native,
             provider_name: provider_name
           }
         }
       )
       when provider_name not in ["", "unknown"],
       do: provider_name

  defp provider_name(%{model: %{provider: provider}}, _state) when is_binary(provider),
    do: provider

  defp provider_name(%{provider: provider}, _state) when is_binary(provider), do: provider
  defp provider_name(_provider_state, state), do: state.provider.provider_name

  @spec provider_model(map(), state()) :: String.t() | nil
  defp provider_model(%{model: %{id: id}}, _state) when is_binary(id), do: id
  defp provider_model(%{model: model}, _state) when is_binary(model), do: model

  defp provider_model(
         _provider_state,
         %{provider: %ProviderLifecycle{model_name: "unknown"}}
       ),
       do: nil

  defp provider_model(_provider_state, state), do: state.provider.model_name

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
    case Keyword.get(state.provider.opts, :project_root) do
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
    {state, _result} = refresh_credentials_state_result(state)
    state
  end

  @spec refresh_credentials_state_result(state()) :: {state(), :ok | {:error, term()}}
  defp refresh_credentials_state_result(state) do
    # Only the native provider resolves its own credentials from the
    # environment. Custom providers, and any caller that injects its own
    # `:llm_client` (tests, embedded transports), manage their own auth, so
    # treat them as always ready.
    configured? =
      session_credentials_configured?(
        state.provider.module,
        state.provider.opts,
        state.credentials_configured_fn
      )

    state = %{state | credentials_configured: configured?}
    {state, result} = maybe_start_provider_result(state)
    broadcast(state, {:credentials_status, configured?})
    {state, result}
  end

  @spec update_model_configuration(state(), String.t()) :: state()
  defp update_model_configuration(state, model) do
    {provider_name, provider_opts} =
      session_provider_configuration(
        state.provider.module,
        model,
        state.provider.opts
      )

    lifecycle =
      ProviderLifecycle.replace(
        state.provider,
        model,
        provider_name,
        provider_opts
      )

    state = %{state | provider: lifecycle}

    case TurnExecution.recover(state.turn_execution) do
      {:changed, execution} -> %{state | turn_execution: execution}
      :unchanged -> state
    end
  end

  @spec provider_restart_options(keyword()) :: keyword()
  defp provider_restart_options(opts) do
    Enum.reduce(@provider_restart_options, [], fn {session_key, lifecycle_key}, restart_opts ->
      case Keyword.fetch(opts, session_key) do
        {:ok, value} -> Keyword.put(restart_opts, lifecycle_key, value)
        :error -> restart_opts
      end
    end)
  end

  @spec session_provider_configuration(module(), String.t(), keyword()) :: {String.t(), keyword()}
  defp session_provider_configuration(provider_module, model, provider_opts) do
    provider = session_model_provider(provider_module, model)

    provider_opts =
      provider_opts
      |> Keyword.put(:model, model)
      |> maybe_put_provider(provider)

    {session_provider_name(provider, provider_opts), provider_opts}
  end

  @spec session_model_provider(module(), String.t()) :: String.t() | nil
  defp session_model_provider(MingaAgent.Providers.Native, model) do
    case AgentConfig.extract_provider_prefix(model) do
      "" -> nil
      provider -> String.downcase(provider)
    end
  end

  defp session_model_provider(_provider_module, _model), do: nil

  @spec session_provider_name(String.t() | nil, keyword()) :: String.t()
  defp session_provider_name(provider, _provider_opts) when is_binary(provider), do: provider

  defp session_provider_name(_provider, provider_opts) do
    provider_opts
    |> Keyword.get(:provider, "unknown")
    |> to_string()
  end

  @spec maybe_put_provider(keyword(), String.t() | nil) :: keyword()
  defp maybe_put_provider(provider_opts, nil), do: provider_opts
  defp maybe_put_provider(provider_opts, ""), do: provider_opts

  defp maybe_put_provider(provider_opts, provider) when is_binary(provider) do
    Keyword.put(provider_opts, :provider, provider)
  end

  @spec session_model_name(keyword(), keyword()) :: String.t()
  defp session_model_name(opts, provider_opts) do
    unconfigured_model = AgentConfig.unconfigured_model()

    case Keyword.get(opts, :model_name) do
      model when is_binary(model) and model != "" and model != unconfigured_model ->
        model

      _ ->
        provider_model_name(provider_opts, unconfigured_model) || unconfigured_model
    end
  end

  @spec provider_model_name(keyword(), String.t()) :: String.t() | nil
  defp provider_model_name(provider_opts, unconfigured_model) do
    case Keyword.get(provider_opts, :model) do
      model when is_binary(model) and model != "" and model != unconfigured_model ->
        model

      _ ->
        nil
    end
  end

  @spec maybe_start_provider_result(state()) :: {state(), :ok | {:error, term()}}
  defp maybe_start_provider_result(%{provider: provider, credentials_configured: true} = state)
       when ProviderLifecycle.is_detached(provider) do
    lifecycle = state.provider

    if provider_startable?(lifecycle.module, lifecycle.opts, lifecycle.model_name) do
      {:start, lifecycle, effects} = ProviderLifecycle.start(lifecycle)
      state = install_provider_transition(state, lifecycle, effects)

      case start_provider(state) do
        {:ok, pid, state} ->
          {attach_provider(state, pid), :ok}

        {:error, reason, state} ->
          state = report_provider_start_error(state, reason)
          state = maybe_schedule_provider_restart(state, reason)
          broadcast(state, {:error, TurnExecution.error(state.turn_execution)})
          {state, {:error, TurnExecution.error(state.turn_execution)}}
      end
    else
      {state, :ok}
    end
  end

  defp maybe_start_provider_result(state), do: {state, :ok}

  @spec attach_provider(state(), pid()) :: state()
  defp attach_provider(state, pid) do
    Process.unlink(pid)
    Process.monitor(pid)
    {lifecycle, effects} = ProviderLifecycle.attach(state.provider, pid)

    state = install_provider_transition(state, lifecycle, effects)
    state = clear_provider_start_error(state)

    state = seed_provider_messages(state, Transcript.messages(state.transcript))
    state = apply_pending_thinking_level(state)
    state = maybe_show_auth_onboarding(state)
    dispatch_session_start(state)
    state
  end

  @spec clear_provider_start_error(state()) :: state()
  defp clear_provider_start_error(state) do
    case TurnExecution.recover(state.turn_execution) do
      {:changed, execution} -> %{state | turn_execution: execution}
      :unchanged -> state
    end
  end

  @spec report_provider_start_error(state(), term()) :: state()
  defp report_provider_start_error(state, reason) do
    Minga.Log.error(:agent, "[Agent.Session] failed to start provider: #{inspect(reason)}")
    {lifecycle, effects} = ProviderLifecycle.failure(state.provider, reason)
    state = install_provider_transition(state, lifecycle, effects)

    mark_provider_failed(state, format_error(reason))
  end

  @spec handle_provider_death(state(), term()) :: state()
  defp handle_provider_death(state, reason) do
    Minga.Log.warning(:agent, "[Agent.Session] provider process died: #{inspect(reason)}")
    {lifecycle, effects} = ProviderLifecycle.failure(state.provider, reason)
    state = install_provider_transition(state, lifecycle, effects)

    state = mark_provider_failed(state, "Agent provider crashed")
    state = maybe_schedule_provider_restart(state, reason)
    broadcast(state, {:error, TurnExecution.error(state.turn_execution)})
    state
  end

  @spec maybe_schedule_provider_restart(state(), term()) :: state()
  defp maybe_schedule_provider_restart(state, reason) do
    case ProviderLifecycle.retry(
           state.provider,
           reason,
           System.monotonic_time(:millisecond)
         ) do
      {:retry, lifecycle, delay_ms, effects} ->
        state = install_provider_transition(state, lifecycle, effects)
        token = make_ref()
        timer_ref = Process.send_after(self(), {:start_provider, token}, delay_ms)
        {:ok, lifecycle} = ProviderLifecycle.install_retry_timer(state.provider, timer_ref, token)

        %{state | provider: lifecycle}
        |> put_provider_retrying_error(delay_ms)

      {:terminal_failure, lifecycle, effects} ->
        state
        |> install_provider_transition(lifecycle, effects)
        |> put_provider_restart_exhausted_error()
    end
  end

  @spec install_provider_transition(
          state(),
          ProviderLifecycle.t(),
          ProviderLifecycle.effects()
        ) :: state()
  defp install_provider_transition(state, lifecycle, effects) do
    Enum.each(effects, &perform_provider_effect/1)
    %{state | provider: lifecycle}
  end

  @spec perform_provider_effect(ProviderLifecycle.effect()) :: :ok
  defp perform_provider_effect({:stop_provider, pid}) do
    monitor_ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        :ok
    after
      @provider_stop_timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
        end
    end
  end

  defp perform_provider_effect({:cancel_timer, timer_ref}) do
    _cancelled? = Process.cancel_timer(timer_ref)
    :ok
  end

  defp perform_provider_effect({:release_lease, lease}), do: release_provider_lease(lease)

  @spec stop_provider_lifecycle(state()) :: state()
  defp stop_provider_lifecycle(state) do
    {lifecycle, effects} = ProviderLifecycle.stop(state.provider)
    install_provider_transition(state, lifecycle, effects)
  end

  @spec put_provider_retrying_error(state(), pos_integer()) :: state()
  defp put_provider_retrying_error(state, delay_ms) do
    seconds = Float.round(delay_ms / 1000, 1)
    attempts = ProviderLifecycle.retry_attempts(state.provider)
    max_attempts = state.provider.restart_policy.max_attempts
    cause = provider_restart_cause(state)

    message =
      "#{cause}. Retrying in #{seconds}s (attempt #{attempts}/#{max_attempts}). Press Ctrl-C to retry now, or run /clear to reset."

    {:ok, execution} = TurnExecution.update_failure(state.turn_execution, message)
    %{state | turn_execution: execution}
  end

  @spec put_provider_restart_exhausted_error(state()) :: state()
  defp put_provider_restart_exhausted_error(state) do
    cause = provider_restart_cause(state)

    message =
      "#{cause}. Automatic restart stopped. Press Ctrl-C to retry now, or run /clear to reset."

    {:ok, execution} = TurnExecution.update_failure(state.turn_execution, message)
    %{state | turn_execution: execution}
  end

  @spec provider_restart_cause(state()) :: String.t()
  defp provider_restart_cause(state) do
    case TurnExecution.error(state.turn_execution) do
      message when is_binary(message) and message != "" -> String.trim_trailing(message, ".")
      nil -> "Agent provider unavailable"
    end
  end

  # Shows an onboarding message when no credentials are configured and the
  # native provider is active. Only fires once per session. Relies on the
  # `credentials_configured` flag set by `refresh_credentials_state/1`.
  @spec maybe_show_auth_onboarding(state()) :: state()
  defp maybe_show_auth_onboarding(state) do
    if state.provider.module == MingaAgent.Providers.Native and
         not state.credentials_configured do
      msg = onboarding_message()
      state = append_system_message(state, msg, :info)
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
      /login --manual           Sign in by pasting a browser redirect

    Ollama is detected automatically if it's running locally.
    Run /auth to see status for all providers.\
    """
  end

  # Turns provider errors into one human line for the transcript. New provider
  # paths pass structured `Event.Error.kind` and `provider` fields, so the
  # session does not infer meaning from text. The string classifier below is
  # only a compatibility fallback for external providers or old persisted events
  # that still send `kind: :unknown`.
  @spec humanize_error(Event.Error.t(), state()) :: String.t()
  defp humanize_error(%Event.Error{kind: :unknown, message: message, provider: provider}, state) do
    humanize_legacy_error(message, provider || provider_slug(state))
  end

  defp humanize_error(%Event.Error{kind: kind, message: message, provider: provider}, state) do
    humanize_error_kind(kind, message, provider || provider_slug(state))
  end

  @spec humanize_error_kind(Event.Error.kind(), String.t(), String.t()) :: String.t()
  defp humanize_error_kind(:auth_failed, _message, provider),
    do: "Couldn't authenticate with #{provider_label(provider)}. #{auth_hint(provider)}"

  defp humanize_error_kind(:rate_limited, _message, _provider),
    do: "The model provider is rate limiting requests. Wait a moment, then try again."

  defp humanize_error_kind(:unreachable, _message, _provider),
    do: "Couldn't reach the model provider. Check your network connection, then try again."

  defp humanize_error_kind(:invalid_model, message, _provider), do: message

  defp humanize_error_kind(:provider_error, _message, _provider) do
    "The model provider returned an unexpected error. Open Messages for details, or pick another configured model with /model."
  end

  defp humanize_error_kind(:tool_error, message, _provider), do: message

  defp humanize_error_kind(:internal_error, _message, _provider) do
    "The model provider returned an unexpected error. Open Messages for details, or pick another configured model with /model."
  end

  @type legacy_error_kind ::
          :auth_failed | :rate_limited | :unreachable | :raw_dump | :passthrough

  @spec humanize_legacy_error(String.t(), String.t()) :: String.t()
  defp humanize_legacy_error(message, provider) when is_binary(message) do
    humanize_legacy_error_kind(classify_legacy_error(message), message, provider)
  end

  defp humanize_legacy_error(message, provider),
    do: humanize_legacy_error(inspect(message), provider)

  @spec classify_legacy_error(String.t()) :: legacy_error_kind()
  defp classify_legacy_error(message) do
    classify_legacy_error_checks([
      {:auth_failed,
       String.match?(message, ~r/\b(401|403)\b/) or
         String.contains?(message, [
           "unauthorized",
           "Unauthorized",
           "invalid_api_key",
           "api_key",
           "API_KEY",
           "provider_build_failed",
           "Failed to build",
           "Couldn't authenticate"
         ])},
      {:rate_limited,
       String.match?(message, ~r/\b429\b/) or String.contains?(message, "rate limit")},
      {:unreachable,
       String.contains?(message, [
         "http_streaming_failed",
         "econnrefused",
         "nxdomain",
         "timed out"
       ])},
      {:raw_dump, raw_struct_dump?(message)}
    ])
  end

  @spec classify_legacy_error_checks([{legacy_error_kind(), boolean()}]) :: legacy_error_kind()
  defp classify_legacy_error_checks([{kind, true} | _rest]), do: kind

  defp classify_legacy_error_checks([{_kind, false} | rest]),
    do: classify_legacy_error_checks(rest)

  defp classify_legacy_error_checks([]), do: :passthrough

  @spec humanize_legacy_error_kind(legacy_error_kind(), String.t(), String.t()) :: String.t()
  defp humanize_legacy_error_kind(:auth_failed, _message, provider),
    do: "Couldn't authenticate with #{provider_label(provider)}. #{auth_hint(provider)}"

  defp humanize_legacy_error_kind(:rate_limited, _message, _provider),
    do: "The model provider is rate limiting requests. Wait a moment, then try again."

  defp humanize_legacy_error_kind(:unreachable, _message, _provider),
    do: "Couldn't reach the model provider. Check your network connection, then try again."

  defp humanize_legacy_error_kind(:raw_dump, _message, _provider),
    do:
      "The model provider returned an unexpected error. Open Messages for details, or pick another configured model with /model."

  defp humanize_legacy_error_kind(:passthrough, message, _provider), do: message

  @spec provider_slug(state()) :: String.t()
  defp provider_slug(%{provider: %ProviderLifecycle{provider_name: provider_name}})
       when is_binary(provider_name) and provider_name != "" do
    provider_name
  end

  defp provider_slug(%{provider: %ProviderLifecycle{model_name: model_name}})
       when is_binary(model_name) do
    case String.split(model_name, ":", parts: 2) do
      [provider | _rest] when provider != "" -> provider
      _other -> "provider"
    end
  end

  defp provider_slug(_state), do: "provider"

  @spec provider_label(String.t()) :: String.t()
  defp provider_label("provider"), do: "the model provider"
  defp provider_label("openai_codex"), do: "OpenAI Codex"

  defp provider_label(provider) do
    provider
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @spec auth_hint(String.t()) :: String.t()
  defp auth_hint("openai_codex") do
    "Sign in with /login for Codex models, or pick another configured model with /model."
  end

  defp auth_hint("provider"),
    do: "Run /auth to check credentials, or pick another configured model with /model."

  defp auth_hint(provider),
    do: "Run /auth #{provider} <key> or pick another configured model with /model."

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
      dispatch_optional(state.provider.module, :set_thinking_level, [
        ProviderLifecycle.pid(state.provider),
        level
      ])
    catch
      :exit, _ -> :ok
    end

    %{state | pending_thinking_level: nil}
  end

  # Calls an optional callback on the provider module. Returns `{:error, :not_supported}`
  # if the provider doesn't implement the callback.
  @spec dispatch_optional(module(), atom(), [term()]) :: term()
  defp dispatch_optional(module, function, args) do
    if function_exported?(module, function, Enum.count(args)) do
      apply(module, function, args)
    else
      {:error, :not_supported}
    end
  end

  # Determines which provider module to use. If an explicit `:provider` option is
  # passed (common in tests and from existing code), use that as a config-owned provider. Otherwise, delegate
  # to the ProviderResolver which checks config and the provider registry.
  @spec session_credentials_configured?(module(), keyword(), credentials_configured_fn()) ::
          boolean()
  defp session_credentials_configured?(provider_module, provider_opts, credentials_configured_fn) do
    provider_module != MingaAgent.Providers.Native or
      Keyword.has_key?(provider_opts, :llm_client) or
      credentials_configured_fn.()
  end

  @spec provider_startable?(module(), keyword(), String.t()) :: boolean()
  defp provider_startable?(provider_module, provider_opts, model_name) do
    provider_module != MingaAgent.Providers.Native or
      Keyword.has_key?(provider_opts, :llm_client) or
      model_name != AgentConfig.unconfigured_model()
  end

  @spec unconfigured_provider_resolution() :: ProviderResolver.resolved()
  defp unconfigured_provider_resolution do
    %ProviderResolver.Resolved{
      id: "unconfigured",
      source: :config,
      module: MingaAgent.Providers.Native,
      name: "unconfigured",
      display_name: "Unconfigured",
      spec: nil
    }
  end

  @spec resolve_provider(keyword()) :: ProviderResolver.resolved()
  defp resolve_provider(opts) do
    case Keyword.fetch(opts, :provider) do
      {:ok, module} when is_atom(module) ->
        %ProviderResolver.Resolved{
          id: Keyword.get(opts, :provider_id, "explicit"),
          source: Keyword.get(opts, :provider_source, :config),
          module: module,
          name: "explicit",
          display_name: "explicit",
          spec: nil
        }

      _ ->
        ProviderResolver.resolve()
    end
  end

  # ── Session persistence ─────────────────────────────────────────────────────

  @save_debounce_ms 500

  @spec schedule_save(state()) :: state()
  defp schedule_save(state) do
    {persistence, timer_to_cancel} = Persistence.changed(state.persistence)

    cancel_runtime_timer(timer_to_cancel)

    persistence =
      if Persistence.dirty?(persistence) do
        token = make_ref()
        timer_ref = Process.send_after(self(), {:save_session, token}, @save_debounce_ms)
        Persistence.scheduled(persistence, token, timer_ref)
      else
        persistence
      end

    %{state | persistence: persistence}
  end

  @spec cancel_save_timer(state()) :: state()
  defp cancel_save_timer(state) do
    {persistence, timer_to_cancel} = Persistence.cancel(state.persistence)
    cancel_runtime_timer(timer_to_cancel)
    %{state | persistence: persistence}
  end

  @spec cancel_runtime_timer({reference(), reference()} | nil) :: :ok
  defp cancel_runtime_timer(nil), do: :ok

  defp cancel_runtime_timer({_token, timer_ref}) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  @spec save_to_disk(state()) :: :ok | {:error, term()}
  defp save_to_disk(state) do
    if Persistence.enabled?(state.persistence) do
      now = DateTime.to_iso8601(DateTime.utc_now())
      last_message_at = DateTime.to_iso8601(Transcript.last_changed_at(state.transcript))

      data = %{
        id: state.session_id,
        timestamp: now,
        last_message_at: last_message_at,
        title:
          readable_title(first_assistant_text(Transcript.messages(state.transcript))) ||
            readable_title(first_user_prompt(Transcript.messages(state.transcript))),
        model_name: state.provider.model_name,
        provider_name: state.provider.provider_name,
        messages: Transcript.messages(state.transcript),
        message_ids:
          state.transcript
          |> Transcript.messages_with_ids()
          |> Enum.map(&elem(&1, 0)),
        pinned_ids: Transcript.pinned_ids(state.transcript),
        usage: Transcript.usage(state.transcript),
        branches: Transcript.branches(state.transcript),
        memory: Memory.read(state.session_store_dir)
      }

      SessionStore.save(data, state.session_store_dir)
    else
      :ok
    end
  end

  @spec schedule_save_retry(state()) :: state()
  defp schedule_save_retry(state) do
    {persistence, delay_ms} = Persistence.failed(state.persistence)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:save_session, token}, delay_ms)
    %{state | persistence: Persistence.scheduled(persistence, token, timer_ref)}
  end

  @spec restore_loaded_session(state(), SessionStore.session_data()) ::
          {:ok, state()} | {:error, term()}
  defp restore_loaded_session(state, data) do
    case persist_current_before_replacement(state, data.id) do
      :ok ->
        state = cancel_save_timer(state)
        loaded_at = parse_datetime(Map.get(data, :last_message_at)) || DateTime.utc_now()

        provider_name =
          Map.get(data, :provider_name, state.provider.provider_name)

        provider_opts = Keyword.put(state.provider.opts, :model, data.model_name)

        lifecycle =
          ProviderLifecycle.replace(
            state.provider,
            data.model_name,
            provider_name,
            provider_opts
          )

        transcript =
          Transcript.restore(
            data.messages,
            data.message_ids,
            Map.get(data, :branches, []),
            data.usage,
            Map.get(data, :pinned_ids, MapSet.new()),
            loaded_at
          )

        execution = TurnExecution.restore(state.turn_execution)
        state = restore_turn_execution(state, execution)

        {persistence, timer_to_cancel} = Persistence.restored(state.persistence)

        cancel_runtime_timer(timer_to_cancel)

        state = %{
          state
          | session_id: data.id,
            transcript: transcript,
            persistence: persistence,
            provider: lifecycle,
            turn_execution: execution,
            created_at: loaded_at
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
        state =
          seed_provider_messages(state, Transcript.messages(state.transcript))

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
  defp apply_loaded_model_to_provider(%{provider: provider})
       when ProviderLifecycle.is_detached(provider),
       do: :ok

  defp apply_loaded_model_to_provider(state) do
    dispatch_optional(state.provider.module, :set_model, [
      ProviderLifecycle.pid(state.provider),
      state.provider.model_name
    ])

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

  @spec first_assistant_text([Message.t()]) :: String.t() | nil
  defp first_assistant_text(messages) do
    Enum.find_value(messages, fn
      {:assistant, text} when is_binary(text) and text != "" -> text
      _ -> nil
    end)
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

    provider = titleize(state.provider.provider_name)

    model =
      state.provider.model_name |> AgentConfig.strip_provider_prefix() |> titleize()

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

  @impl GenServer
  @spec terminate(term(), state()) :: :ok
  def terminate(reason, state) do
    record_critical_event(state, :session_stopped, %{
      reason: inspect(reason),
      status: TurnExecution.status(state.turn_execution)
    })

    dispatch_session_end(state, reason)
    state = release_subscriber_lifecycle(state)
    _stopped_state = stop_provider_lifecycle(state)

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

  @spec release_subscriber_lifecycle(state()) :: state()
  defp release_subscriber_lifecycle(state) do
    {lifecycle, timer_ref, monitor_refs} = SubscriberLifecycle.stop(state.subscriber_lifecycle)
    cancel_reclaim_timer(timer_ref)
    Enum.each(monitor_refs, &Process.demonitor(&1, [:flush]))
    %{state | subscriber_lifecycle: lifecycle}
  end

  # ── Hook dispatching ──────────────────────────────────────────────────────

  @spec dispatch_session_start(state()) :: :ok
  defp dispatch_session_start(%{hooks_enabled?: false}), do: :ok
  defp dispatch_session_start(%{session_start_hook_enabled?: false}), do: :ok

  defp dispatch_session_start(state) do
    payload =
      SessionStartPayload.new(
        state.session_id,
        state.provider.model_name,
        state.provider.provider_name
      )

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
    payload =
      SessionEndPayload.new(state.session_id, reason, TurnExecution.status(state.turn_execution))

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

  @spec dispatch_stop(state()) :: state()
  defp dispatch_stop(%{hooks_enabled?: false} = state), do: state

  defp dispatch_stop(state) do
    last_message = extract_last_assistant_text(Transcript.messages(state.transcript))
    payload = StopPayload.new(state.session_id, :end_turn, last_message)
    HookDispatcher.stop(AgentConfig.resolve().agent_hooks, StopPayload.to_map(payload))
    state
  rescue
    e ->
      Minga.Log.warning(:agent, "Stop hook dispatch failed: #{Exception.message(e)}")
      state
  catch
    _, reason ->
      Minga.Log.warning(:agent, "Stop hook dispatch failed: #{inspect(reason)}")
      state
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
