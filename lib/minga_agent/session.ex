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
  alias MingaAgent.Checklist
  alias Minga.Extension.CodeLease
  alias MingaAgent.CodexModels
  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Credentials
  alias MingaAgent.Credentials.Snapshot, as: CredentialSnapshot
  alias MingaAgent.Credentials.Secret
  alias MingaAgent.DraftAttachment
  alias MingaAgent.DraftSnapshot
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
  alias MingaAgent.InferenceRouteRegistry
  alias MingaAgent.InferenceRouteRegistry.UsageLimits
  alias MingaAgent.Memory
  alias MingaAgent.ArtifactStores
  alias MingaAgent.ArtifactStore
  alias MingaAgent.ArtifactStores.Runtime, as: ArtifactRuntime
  alias MingaAgent.Message
  alias MingaAgent.Notifier
  alias MingaAgent.ModelCandidate
  alias MingaAgent.ModelResolver
  alias MingaAgent.ModelSelection
  alias MingaAgent.ModelSelection.Policy.RequestCapacity
  alias MingaAgent.ModelSelection.Stored
  alias MingaAgent.ProviderRegistry
  alias MingaAgent.ProviderResolver
  alias MingaAgent.Question
  alias MingaAgent.Question.Pending, as: PendingQuestion
  alias MingaAgent.Question.Target, as: QuestionTarget
  alias MingaAgent.SessionMetadata
  alias MingaAgent.Session.ChecklistArchive
  alias MingaAgent.Session.Connection
  alias MingaAgent.Session.ConnectionSnapshot
  alias MingaAgent.Session.ConnectionTarget
  alias MingaAgent.Session.Continuation
  alias MingaAgent.Session.Dispatch
  alias MingaAgent.Session.ModelSwitch
  alias MingaAgent.Session.FileChange
  alias MingaAgent.Session.Outcome
  alias MingaAgent.Session.Prefix
  alias MingaAgent.Session.PrefixStore
  alias MingaAgent.Session.Request
  alias MingaAgent.Session.ProviderLifecycle
  alias MingaAgent.Session.Persistence
  alias MingaAgent.Session.SubscriberAttachment
  alias MingaAgent.Session.SubscriberLifecycle
  alias MingaAgent.Session.Transcript
  alias MingaAgent.Session.QueuedInputSummary
  alias MingaAgent.Session.TurnExecution
  require ProviderLifecycle
  alias MingaAgent.SessionManager
  alias MingaAgent.SessionStore
  alias MingaAgent.SubagentContext
  alias MingaAgent.ToolApproval
  alias MingaAgent.UsageLimit
  alias MingaAgent.ToolApproval.Public, as: PublicApproval
  alias MingaAgent.ToolApproval.Target, as: ApprovalTarget
  alias MingaAgent.ToolCall
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Codec, as: OutputCodec
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Output.Reference
  alias MingaAgent.Tool.Invocation
  alias MingaAgent.Tool.Registry, as: ToolRegistry
  alias MingaAgent.Tool.Spec, as: ToolSpec
  alias MingaAgent.Session.JobLedger
  alias MingaAgent.Session.JobLedger.Record, as: JobRecord
  alias MingaAgent.Session.JobNotice
  alias MingaAgent.Tools.JobOwner
  alias MingaAgent.Providers.Native.ReqLLMAdapter
  alias ReqLLM.Context

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

  @typedoc "Callback that acquires one local credential snapshot."
  @type credentials_snapshot_fn :: (-> CredentialSnapshot.t())

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
          custom_title: String.t() | nil,
          archived?: boolean(),
          artifact_runtime: ArtifactRuntime.t() | nil,
          workdir: String.t() | nil,
          event_log_server: GenServer.server(),
          event_log_failure: event_log_failure() | nil,
          provider: ProviderLifecycle.t(),
          credentials_configured_fn: credentials_configured_fn() | nil,
          credentials_snapshot_fn: credentials_snapshot_fn(),
          credential_readiness: Credentials.readiness(),
          connection: Connection.t(),
          turn_execution: TurnExecution.t(),
          transcript: Transcript.t(),
          continuation: Continuation.t(),
          checklist: Checklist.t(),
          checklist_archive: ChecklistArchive.t(),
          file_changes: [FileChange.t()],
          subscriber_lifecycle: SubscriberLifecycle.t(),
          tool_approval_policy: tool_approval_policy(),
          tool_authority: map(),
          idle_gc_timeout_ms: non_neg_integer(),
          persistence: Persistence.t(),
          model_selection: ModelSelection.t() | nil,
          unresolved_route: unresolved_route() | nil,
          model_discovery:
            {:atomics.atomics_ref(), CodexModels.result(),
             ModelResolver.apple_availability() | nil}
            | nil,
          model_discovery_request: reference() | nil,
          apple_selection_probe:
            {reference(), pid(), ConnectionTarget.t(), ModelResolver.intent()} | nil,
          pending_model_change: ModelSelection.t() | String.t() | nil,
          pending_thinking_level: String.t() | nil,
          notifier: module() | {module(), term()},
          background_subagent: boolean(),
          hooks_enabled?: boolean(),
          session_start_hook_enabled?: boolean(),
          hook_task_supervisor: GenServer.server(),
          session_store_dir: String.t() | nil,
          session_manager: pid() | nil,
          created_at: DateTime.t(),
          credentials_configured: boolean(),
          job_owner: pid() | nil,
          job_owner_ref: reference() | nil,
          job_epoch: non_neg_integer(),
          job_ledger: JobLedger.t(),
          job_admissions: %{reference() => JobRecord.id()}
        }

  @provider_stop_timeout_ms 1_000
  @boundary_save_failure_message "Conversation save failed. The previous durable boundary remains resumable; this change is not yet durable."
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

  @doc """
  Starts a new agent session.

  `:subscribers` is a list of `{pid, subscribe_opts}` attached inside `init/1`, before provider start is queued, so no subscriber waits behind provider start or SessionStart hooks. With `:start_token`, each initial subscriber first receives `{:agent_event, session, {:session_start_attached, token}}`, which orders the start acknowledgement ahead of every other event from this session.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc "Returns this durable record's retained-artifact authority."
  @spec artifact_store(GenServer.server()) :: {:ok, GenServer.server()} | {:error, term()}
  def artifact_store(session), do: GenServer.call(session, :artifact_store)

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

  @doc """
  Sends a prompt only when the Session still has the expected identity.

  Returns `{:error, :session_id_changed}` when a manager lookup became stale.
  """
  @spec send_prompt_for_id(
          GenServer.server(),
          String.t(),
          String.t() | [ReqLLM.Message.ContentPart.t()]
        ) :: :ok | {:queued, :steering} | {:error, term()}
  def send_prompt_for_id(session, expected_session_id, content) do
    send_prompt_for_id(session, expected_session_id, content, 5_000)
  end

  @doc """
  Sends a prompt only when the Session still has the expected identity.

  Use the timeout to bound an asynchronous caller's wait for prompt admission.
  Returns `{:error, :session_id_changed}` when a manager lookup became stale.
  """
  @spec send_prompt_for_id(
          GenServer.server(),
          String.t(),
          String.t() | [ReqLLM.Message.ContentPart.t()],
          non_neg_integer() | :infinity
        ) :: :ok | {:queued, :steering} | {:error, term()}
  def send_prompt_for_id(session, expected_session_id, content, timeout)
      when is_binary(expected_session_id) and (is_binary(content) or is_list(content)) do
    GenServer.call(session, {:send_prompt_for_id, expected_session_id, content}, timeout)
  end

  @doc "Starts an ordinary local composer send without treating an intervening active turn as a queue acceptance."
  @spec send_idle_composer(GenServer.server(), String.t(), TurnExecution.content()) ::
          :ok | {:error, term()}
  def send_idle_composer(session, record_id, content) do
    GenServer.call(session, {:send_idle_composer, record_id, content})
  end

  @doc "Submits the displayed set of retained draft attachments to the still-matching local record."
  @spec send_attached_prompt(
          GenServer.server(),
          String.t(),
          [DraftAttachment.identity()],
          String.t() | [ReqLLM.Message.ContentPart.t()]
        ) :: {:ok, non_neg_integer()} | {:accepted, non_neg_integer(), term()} | {:error, term()}
  def send_attached_prompt(session, record_id, [_ | _] = shown, content) do
    GenServer.call(session, {:send_attached_prompt, record_id, shown, content})
  end

  @doc "Aborts only when the Session still has the expected identity."
  @spec abort_for_id(GenServer.server(), String.t()) :: :ok | {:error, :session_id_changed}
  def abort_for_id(session, expected_session_id) when is_binary(expected_session_id) do
    GenServer.call(session, {:abort_for_id, expected_session_id})
  end

  @doc """
  Aborts only the turn running the named request in the Session with the expected identity.

  Returns `{:error, :stale_turn}` when that request is no longer running, so a late abort cannot stop a later turn.
  """
  @spec abort_for_id(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, :session_id_changed | :stale_turn}
  def abort_for_id(session, expected_session_id, request_id)
      when is_binary(expected_session_id) and is_binary(request_id) do
    GenServer.call(session, {:abort_for_id, expected_session_id, request_id})
  end

  @doc """
  Stops the matching turn and keeps every queued input queued.

  The Session reports the status `:stopped` until the next turn starts; the queue is sent after that turn, as it would have been after the stopped one.
  """
  @spec stop_turn(GenServer.server(), {String.t(), String.t()}) :: :ok | {:error, :stale_turn}
  def stop_turn(session, target), do: GenServer.call(session, {:stop_turn, target})

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
  @spec seed_messages(GenServer.server(), [Message.t()]) :: :ok | {:error, term()}
  def seed_messages(session, messages) when is_list(messages) do
    GenServer.call(session, {:seed_messages, messages})
  end

  @doc "Starts a transcript seed without waiting; the reply is `seed_messages/2`'s result."
  @spec request_seed_messages(pid(), [Message.t()]) :: :gen_server.request_id()
  def request_seed_messages(session, messages)
      when is_pid(session) and node(session) == node() and is_list(messages) do
    :gen_server.send_request(session, {:seed_messages, messages})
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
    GenServer.call(session, :subagent_context, 15_000)
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
          display_status: TurnExecution.display_status(),
          stop_target: {String.t(), String.t()} | nil,
          pending_approval: PublicApproval.t() | nil,
          pending_question: {QuestionTarget.t(), Question.t()} | nil,
          queue_target: queue_target() | nil,
          error: String.t() | nil,
          active_tool_name: String.t() | nil,
          active_tools: [TurnExecution.active_tool()],
          checklist: Checklist.t(),
          credentials_configured: boolean(),
          credential_readiness: Credentials.readiness(),
          model_selection: ModelSelection.t() | nil,
          connection: ConnectionSnapshot.t()
        }

  @typedoc "One local arrival's ordered snapshot and transcript projection."
  @type editor_arrival :: {editor_snapshot(), editor_arrival_transcript()}
  @type editor_arrival_transcript ::
          {:unchanged, Transcript.Cursor.t()}
          | {:changes, Transcript.Changes.t()}
          | {:replace, :changed | :reset, Transcript.Snapshot.t(),
             %{String.t() => pos_integer()} | nil}

  @doc "Returns a snapshot of session state for the editor to rebuild AgentState."
  @spec editor_snapshot(GenServer.server()) :: editor_snapshot()
  def editor_snapshot(session) do
    GenServer.call(session, :editor_snapshot)
  end

  @doc "Starts an editor snapshot read without installing a caller-side timeout."
  @spec request_editor_snapshot(pid()) :: :gen_server.request_id()
  def request_editor_snapshot(session) when is_pid(session) and node(session) == node() do
    :gen_server.send_request(session, :editor_snapshot)
  end

  @doc """
  Starts a read of the transcript changes since `cursor` without blocking the caller.

  The reply has the arrival transcript's shape: a replacement carries the changed-file counts, and an invalid cursor answers with a reset snapshot, so one read is always enough.
  """
  @spec request_editor_transcript(pid(), :snapshot | Transcript.Cursor.t()) ::
          :gen_server.request_id()
  def request_editor_transcript(session, cursor) when is_pid(session) and node(session) == node(),
    do: :gen_server.send_request(session, {:editor_transcript, cursor})

  @doc "Requests the final local arrival snapshot in the subscriber's Session event order."
  @spec request_editor_arrival(pid(), :snapshot | Transcript.Cursor.t(), pid(), reference()) ::
          :gen_server.request_id()
  def request_editor_arrival(session, cursor, subscriber, arrival)
      when is_pid(session) and node(session) == node() and is_pid(subscriber) and
             node(subscriber) == node() and is_reference(arrival) do
    :gen_server.send_request(session, {:editor_arrival, cursor, subscriber, arrival})
  end

  @doc "Renames the exact displayed local conversation after its record commits."
  @spec rename_conversation(ConnectionTarget.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def rename_conversation(%ConnectionTarget{session: session} = target, title)
      when node(session) == node() and is_binary(title) do
    GenServer.call(session, {:rename_conversation, target, title})
  end

  def rename_conversation(%ConnectionTarget{}, _title), do: {:error, :unsupported_session}

  @doc "Changes organization only, for the exact displayed local saved conversation."
  @spec set_archived(ConnectionTarget.t(), boolean()) :: :ok | {:error, term()}
  def set_archived(%ConnectionTarget{session: session} = target, archived?)
      when node(session) == node() and is_boolean(archived?) do
    GenServer.call(session, {:set_archived, target, archived?})
  end

  def set_archived(%ConnectionTarget{}, _archived?), do: {:error, :unsupported_session}

  @type composer_draft_operation ::
          :read
          | {:save, SessionStore.draft_revision(), DraftSnapshot.t() | nil}
          | {:recall, SessionStore.draft_revision(), DraftSnapshot.t() | nil, :keep_running}
          | {:queue, queue_target(), TurnExecution.prompt_kind(), queue_draft(),
             TurnExecution.content()}
          | {:reconcile_queue, pos_integer(), String.t(), SessionStore.draft_revision()}
          | {:remove_attachment, SessionStore.draft_revision(), DraftSnapshot.t() | nil}
          | {:attach_text, SessionStore.draft_revision(), DraftSnapshot.t(),
             DraftAttachment.text_snapshot()}

  @type remote_composer_operation ::
          composer_draft_operation()
          | {:inspect_attachment, DraftAttachment.identity()}
          | {:submit, SessionStore.draft_revision(), String.t(), [DraftAttachment.identity()],
             String.t() | [ReqLLM.Message.ContentPart.t()]}
          | {:reconcile_submission, SessionStore.draft_revision(), String.t()}
          | {:confirm_queue_receipt, TurnExecution.queue_receipt()}
          | :read_queue
          | {:withdraw_queued_input, QueuedInputSummary.identity()}
          | {:read_queued_input_text, QueuedInputSummary.identity()}
          | {:edit_queued_input, QueuedInputSummary.identity(), String.t()}

  @type composer_result ::
          {:ok, SessionStore.draft_revision(),
           DraftSnapshot.t() | DraftSnapshot.attachment() | nil}
          | {:ok, SessionStore.draft_revision()}
          | {:ok, DraftSnapshot.attachment(), String.t()}
          | {:ok, TurnExecution.queue_receipt()}
          | {:ok, [QueuedInputSummary.t()]}
          | {:ok, String.t()}
          | :ok
          | {:accepted, SessionStore.draft_revision(), term()}
          | {:admitted, SessionStore.draft_revision()}
          | {:not_admitted, SessionStore.draft_revision()}
          | {:error, term()}

  @doc "Executes a saved-composer operation after checking the exact current attachment receipt."
  @spec remote_composer(pid(), String.t(), {pid(), binary()}, remote_composer_operation()) ::
          composer_result()
  def remote_composer(session, record_id, {driver, receipt} = authority, operation)
      when is_pid(session) and node(session) == node() and is_binary(record_id) and
             is_pid(driver) and is_binary(receipt) do
    GenServer.call(session, {:remote_composer, record_id, authority, operation})
  end

  @type composer_draft_correlation :: reference() | {non_neg_integer(), reference()}

  @doc "Requests a record-bound draft read or commit and reports the outcome to the caller."
  @spec request_composer_draft(
          GenServer.server(),
          String.t(),
          composer_draft_correlation(),
          composer_draft_operation()
        ) :: :ok
  def request_composer_draft(session, record_id, correlation, operation)
      when is_binary(record_id) do
    GenServer.cast(session, {:composer_draft, self(), record_id, correlation, operation})
  end

  @doc "Confirms the local composer applied the exact saved queue reply."
  @spec confirm_queue_receipt(GenServer.server(), String.t(), TurnExecution.queue_receipt()) ::
          :ok
  def confirm_queue_receipt(session, record_id, receipt) when is_binary(record_id) do
    GenServer.cast(session, {:confirm_queue_receipt, self(), record_id, receipt})
  end

  @doc "Reads an exact unsent attachment only from the specified local record."
  @spec read_draft_attachment(GenServer.server(), String.t(), DraftAttachment.identity()) ::
          {:ok, DraftSnapshot.attachment(), String.t()} | {:error, term()}
  def read_draft_attachment(session, record_id, identity),
    do: GenServer.call(session, {:read_draft_attachment, record_id, identity})

  @doc """
  Admits explicitly requested setup against an exact live target.
  A subscriber can receive an optional secret-free input request after its canonical change event.
  """
  @spec begin_connection(
          GenServer.server(),
          ConnectionTarget.t(),
          Connection.method(),
          pid(),
          {pid(), term()} | nil
        ) ::
          {:ok, reference()} | {:error, atom()}
  def begin_connection(session, target, method, owner_pid, notify \\ nil)
      when is_pid(owner_pid) do
    GenServer.call(session, {:begin_connection, target, method, owner_pid, notify})
  end

  @doc "Binds the exact acquisition worker for operation-specific cancellation."
  @spec register_connection_worker(GenServer.server(), ConnectionTarget.t(), reference(), pid()) ::
          :ok | {:error, atom()}
  def register_connection_worker(session, target, operation_ref, worker_pid)
      when is_pid(worker_pid) do
    GenServer.call(session, {:register_connection_worker, target, operation_ref, worker_pid})
  end

  @doc "Binds an acquisition worker from the original owner without waiting on Session."
  @spec request_connection_worker(GenServer.server(), ConnectionTarget.t(), reference(), pid()) ::
          :ok
  def request_connection_worker(session, target, operation_ref, worker_pid)
      when is_pid(worker_pid) do
    GenServer.cast(
      session,
      {:request_connection_worker, target, operation_ref, worker_pid, self()}
    )
  end

  @doc "Cancels only the captured setup operation; committed storage is never rolled back."
  @spec cancel_connection(GenServer.server(), ConnectionTarget.t(), reference()) ::
          :ok | {:error, atom()}
  def cancel_connection(session, target, operation_ref) do
    GenServer.call(session, {:cancel_connection, target, operation_ref})
  end

  @doc """
  Requests exact-operation cancellation without waiting for Session.

  This acknowledges delivery only, not cancellation or rollback of a commit
  that already won Session's serialized persistence boundary.
  """
  @spec request_connection_cancel(GenServer.server(), ConnectionTarget.t(), reference()) :: :ok
  def request_connection_cancel(session, target, operation_ref)
      when is_reference(operation_ref) do
    GenServer.cast(session, {:request_connection_cancel, target, operation_ref, self()})
  end

  @doc "Serializes exact-target API-key installation against cancellation and supersession."
  @spec commit_api_key(
          GenServer.server(),
          ConnectionTarget.t(),
          reference(),
          String.t(),
          Secret.t()
        ) ::
          {:ok, ConnectionSnapshot.t()} | {:error, atom()}
  def commit_api_key(session, target, operation_ref, provider, secret) do
    GenServer.call(session, {:commit_api_key, target, operation_ref, provider, secret})
  end

  @doc "Commits acquired OAuth credentials for the original target and authorized worker."
  @spec commit_oauth(GenServer.server(), ConnectionTarget.t(), reference(), Secret.t()) ::
          {:ok, ConnectionSnapshot.t()} | {:error, atom()}
  def commit_oauth(session, target, operation_ref, secret) do
    GenServer.call(session, {:commit_oauth, target, operation_ref, secret})
  end

  @doc "Reports failure only for the current OAuth operation and its authorized actor."
  @spec report_oauth_failure(GenServer.server(), ConnectionTarget.t(), reference(), atom()) :: :ok
  def report_oauth_failure(session, target, ref, reason) do
    GenServer.cast(session, {:report_oauth_failure, target, ref, reason, self()})
  end

  @doc "Retries the captured connection without submitting or replaying any draft."
  @spec retry_connection(GenServer.server(), ConnectionTarget.t()) :: :ok | {:error, term()}
  def retry_connection(session, target) do
    GenServer.call(session, {:retry_connection, target})
  end

  @doc """
  Atomically queries current transcript entries, stable IDs, pins and source facts.

  Use `:snapshot` for an explicit full snapshot, then the returned runtime cursor
  for coalesced current changes. Reset outcomes contain a replacement snapshot;
  invalid cursors are rejected. Normal GenServer timeout/process exits propagate.
  """
  @spec transcript_since(GenServer.server(), :snapshot | Transcript.Cursor.t()) ::
          Transcript.query_result()
  def transcript_since(session, cursor) do
    GenServer.call(session, {:transcript_since, cursor})
  end

  @doc "Reads up to 64 KiB of the original retained tool output, without rerunning it."
  @spec read_retained_output(
          ConnectionTarget.t(),
          pos_integer(),
          Reference.t(),
          Range.t()
        ) ::
          {:ok, ArtifactStore.Fetched.t()} | {:error, term()}
  def read_retained_output(
        %ConnectionTarget{session: session} = target,
        id,
        %Reference{} = reference,
        %Range{unit: :bytes, start: start, count: count} = range
      )
      when is_integer(id) and id > 0 and is_integer(start) and
             start >= 0 and is_integer(count) and count in 0..65_536 do
    with {:ok, store} <-
           GenServer.call(session, {:retained_output_store, target, id, reference}) do
      ArtifactStore.fetch(store, reference, range)
    end
  end

  def read_retained_output(_target, _id, _reference, _range),
    do: {:error, :invalid_range}

  @doc "Reads the original and latest retained sides for a file in the targeted session."
  @spec read_cumulative_file_change(ConnectionTarget.t(), String.t()) ::
          {:ok, {binary() | :absent, binary() | :absent}} | {:error, term()}
  def read_cumulative_file_change(%ConnectionTarget{session: session} = target, path)
      when is_binary(path) do
    with {:ok, store, before_side, after_side} <-
           GenServer.call(session, {:cumulative_file_change, target, path}),
         {:ok, before_bytes} <- FileChange.read_side(store, before_side),
         {:ok, after_bytes} <- FileChange.read_side(store, after_side),
         {:ok, ^store, ^before_side, ^after_side} <-
           GenServer.call(session, {:cumulative_file_change, target, path}) do
      {:ok, {before_bytes, after_bytes}}
    else
      {:ok, _store, _before_side, _after_side} -> {:error, :file_change_changed}
      {:error, _reason} = error -> error
    end
  end

  @doc "Applies a conditional review mutation only while the displayed Session target is current."
  @spec apply_review_mutation(
          ConnectionTarget.t(),
          MingaAgent.ProjectView.t(),
          String.t(),
          MingaAgent.ProjectView.Source.t(),
          Minga.Buffer.FileMutation.expectation(),
          Minga.Buffer.FileMutation.operation()
        ) :: :ok | {:error, term()}
  def apply_review_mutation(
        %ConnectionTarget{session: session} = target,
        view,
        path,
        source,
        revision,
        operation
      ) do
    GenServer.call(
      session,
      {:apply_review_mutation, target, view, path, source, revision, operation}
    )
  end

  @doc "Returns attributed mutation counts per changed file in the targeted session."
  @spec changed_file_counts(ConnectionTarget.t()) ::
          {:ok, %{String.t() => pos_integer()}} | {:error, :stale_target}
  def changed_file_counts(%ConnectionTarget{session: session} = target),
    do: GenServer.call(session, {:changed_file_counts, target})

  @doc "Reads a bounded history page for an exact conversation target or transcript cursor."
  @spec transcript_history_before(
          GenServer.server(),
          ConnectionTarget.t() | Transcript.Cursor.t(),
          pos_integer() | :tail,
          1..64
        ) :: Transcript.history_result() | {:error, :stale_target}
  def transcript_history_before(session, source, anchor, limit) do
    GenServer.call(session, {:transcript_history_before, source, anchor, limit})
  end

  @doc """
  Resolves the exact session, admitted request and tool approval shown by a control.

  Identity validation and resolution occur together inside the Session callback. A stale target leaves the current approval untouched.
  """
  @type approval_decision :: :approve | :approve_session | :approve_turn | :reject
  @type approval_target :: ApprovalTarget.t()
  @type approval_error ::
          :stale_session | :stale_request | :approval_not_found | :no_pending_approval
  @typep approval_resolution :: {state(), ToolApproval.t(), approval_decision()}
  @typep approval_retirement ::
           {state(), ToolApproval.t(), approval_decision() | :approval_timeout | :interrupted}

  @spec respond_to_approval(GenServer.server(), approval_target(), approval_decision()) ::
          :ok | {:error, approval_error()}
  def respond_to_approval(session, %ApprovalTarget{} = target, decision)
      when decision in [:approve, :approve_session, :approve_turn, :reject] do
    GenServer.call(session, {:respond_to_approval, target, decision})
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

  @typedoc "Why the Session refused to admit a shell job."
  @type job_admission_error :: :no_job_owner | JobLedger.limit_error()

  @doc """
  Admits a shell job in this session's job ledger.

  Allocates the job id, records the job as running under the current JobOwner epoch, and returns the record with the JobOwner that must run it. The caller then passes the record to `JobOwner.start_foreground/3` or `JobOwner.start_background/3`. If the caller exits before a background job starts, or before a foreground job ends, the Session cancels the job so it cannot hold a running slot.
  """
  @spec admit_job(GenServer.server(), JobRecord.spec()) ::
          {:ok, JobRecord.t(), pid()} | {:error, job_admission_error()}
  def admit_job(
        session,
        %{command: command, cwd: cwd, background?: background?, timeout_secs: timeout_secs} =
          spec
      )
      when is_binary(command) and is_binary(cwd) and is_boolean(background?) and
             is_integer(timeout_secs) and timeout_secs > 0 do
    GenServer.call(session, {:admit_job, spec}, 30_000)
  end

  @doc "Returns one job record from this session's ledger."
  @spec job(GenServer.server(), JobRecord.id()) :: {:ok, JobRecord.t()} | {:error, :job_not_found}
  def job(session, job_id) when is_binary(job_id) do
    GenServer.call(session, {:job, job_id})
  end

  @doc "Returns every retained job record, oldest admission first."
  @spec jobs(GenServer.server()) :: [JobRecord.t()]
  def jobs(session), do: GenServer.call(session, :jobs)

  @doc "Cancels a running job through this session's JobOwner."
  @spec cancel_job(GenServer.server(), JobRecord.id()) ::
          :ok | {:error, :job_not_found | :already_terminal}
  def cancel_job(session, job_id) when is_binary(job_id) do
    GenServer.call(session, {:cancel_job, job_id})
  end

  @doc """
  Loads a previously saved session, replacing the current conversation history.

  The current session is saved before replacement. The restored conversation history, branches, model, and metadata become the active session state. A saved model route that cannot resolve now still opens its history: the session has no model selection and its connection snapshot reports the resolution problem until the user chooses a route.

  Pass the currently displayed session ID to reject a delayed activation after this process has changed conversations.
  """
  @spec load_session(GenServer.server(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def load_session(session, session_id, origin_id \\ nil) when is_binary(session_id) do
    GenServer.call(session, {:load_session, session_id, origin_id})
  end

  @doc "Starts loading a saved session without waiting; the reply is `load_session/3`'s result."
  @spec request_load_session(pid(), String.t(), String.t() | nil) :: :gen_server.request_id()
  def request_load_session(session, session_id, origin_id \\ nil)
      when is_pid(session) and node(session) == node() and is_binary(session_id) do
    :gen_server.send_request(session, {:load_session, session_id, origin_id})
  end

  @doc """
  Explicitly imports an unversioned display-only session into a new portable record.

  The source file is never changed. The imported transcript is visibly marked
  as reconstructed and is not represented as lossless provider continuation.
  Pass the currently displayed session ID to reject a delayed activation after this process has changed conversations.
  """
  @spec import_legacy_session(GenServer.server(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def import_legacy_session(session, session_id, origin_id \\ nil) when is_binary(session_id) do
    GenServer.call(session, {:import_legacy_session, session_id, origin_id})
  end

  @doc "Starts a legacy import without waiting; the reply is `import_legacy_session/3`'s result."
  @spec request_import_legacy_session(pid(), String.t(), String.t() | nil) ::
          :gen_server.request_id()
  def request_import_legacy_session(session, session_id, origin_id)
      when is_pid(session) and node(session) == node() and is_binary(session_id) do
    :gen_server.send_request(session, {:import_legacy_session, session_id, origin_id})
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

  @doc "Subscribes the given process, allowing callers to bound startup waits explicitly."
  @spec subscribe(GenServer.server(), pid(), keyword(), timeout()) ::
          :ok | {:error, :invalid_role}
  def subscribe(session, pid, opts, timeout) when is_pid(pid) do
    GenServer.call(session, {:subscribe, pid, opts}, timeout)
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

  @doc "Resolves the exact displayed approval as an attached remote driver."
  @spec respond_to_approval_as(GenServer.server(), pid(), approval_target(), approval_decision()) ::
          :ok | {:error, approval_error() | :not_driver}
  def respond_to_approval_as(session, client_pid, %ApprovalTarget{} = target, decision)
      when is_pid(client_pid) and decision in [:approve, :approve_session, :approve_turn, :reject] do
    GenServer.call(session, {:respond_to_approval_as, client_pid, target, decision})
  end

  @doc "Reads the current question and its exact control target without exposing the tool worker."
  @spec pending_question(GenServer.server()) :: {QuestionTarget.t(), Question.t()} | nil
  def pending_question(session), do: GenServer.call(session, :pending_question)

  @doc "Answers or cancels the displayed question as the attached driver."
  @spec respond_to_question_as(
          GenServer.server(),
          pid() | {pid(), binary()},
          QuestionTarget.t(),
          Question.response()
        ) ::
          :ok | {:error, :not_driver | :question_not_found | :invalid_answer}
  def respond_to_question_as(session, authority, %QuestionTarget{} = target, response) do
    GenServer.call(session, {:respond_to_question_as, authority, target, response})
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

  # A saved route resolved for restore, or the resolution problem that keeps it unavailable.
  @typep saved_route ::
           {:resolved, ModelSelection.t() | nil} | {:unresolved, ModelResolver.resolution_error()}

  # The stored selection and intent of a restored route that did not resolve. Saving writes them
  # back verbatim so an unavailable route keeps its exact route and policy until a model is chosen.
  @typep unresolved_route :: {Stored.t() | nil, map() | nil}

  @typedoc "Internal rollback handle for a broker attach that may have created a monitor."
  @type broker_attachment :: :existing | {:created, pid(), reference()}

  @doc "Subscribes through the broker and reports whether this operation created the attachment."
  @spec broker_attach(GenServer.server(), pid(), attachment_role(), boolean()) ::
          {:ok, broker_attachment()} | {:error, :invalid_role}
  def broker_attach(session, pid, role, questions?) when is_pid(pid) and is_boolean(questions?) do
    GenServer.call(session, {:broker_attach, pid, role, questions?})
  end

  @doc "Rolls back only the monitor installed by a failed broker attach."
  @spec rollback_broker_attach(GenServer.server(), broker_attachment()) :: :ok
  def rollback_broker_attach(_session, :existing), do: :ok

  def rollback_broker_attach(session, {:created, pid, ref}) do
    GenServer.call(session, {:rollback_broker_attach, pid, ref})
  end

  @doc "Atomically authorizes and detaches the current broker attachment."
  @spec broker_detach(GenServer.server(), pid() | {pid(), binary()}) ::
          :ok | {:error, :not_driver}
  def broker_detach(session, authority), do: GenServer.call(session, {:broker_detach, authority})

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

  @doc "Returns the immutable executable model selection owned by this session."
  @spec model_selection(GenServer.server()) :: ModelSelection.t() | nil
  def model_selection(session) do
    GenServer.call(session, :model_selection)
  end

  @doc "Starts a model selection read without waiting; the reply is `model_selection/1`'s result."
  @spec request_model_selection(pid()) :: :gen_server.request_id()
  def request_model_selection(session) when is_pid(session) and node(session) == node() do
    :gen_server.send_request(session, :model_selection)
  end

  @doc "Fetches available models from the provider."
  @spec get_available_models(GenServer.server()) :: {:ok, term()} | {:error, term()}
  def get_available_models(session) do
    GenServer.call(session, :get_available_models, 10_000)
  end

  @doc "Refreshes model and contributed route availability in the calling worker and lists available routes."
  @spec discover_available_models(GenServer.server()) ::
          {:ok, term(), String.t() | :superseded | nil, :atomics.atomics_ref() | nil}
          | {:error, term()}
  def discover_available_models(session) do
    case GenServer.call(session, :begin_model_discovery) do
      {:native, ref, credential, credential_opts, resolver_opts} ->
        refresh_inference_routes(resolver_opts, credential_opts)
        apple = ModelResolver.apple_availability(resolver_opts)
        codex = fetch_codex_models(credential, credential_opts)
        GenServer.call(session, {:finish_model_discovery, ref, credential, codex, apple})

      :local ->
        with {:ok, candidates} <- get_available_models(session), do: {:ok, candidates, nil, nil}
    end
  end

  # Route availability callbacks run in this calling worker, never in the Session or Editor process.
  @spec refresh_inference_routes(keyword(), keyword()) :: :ok
  defp refresh_inference_routes(resolver_opts, credential_opts) do
    resolver_opts
    |> inference_route_registry()
    |> MingaAgent.InferenceRouteRegistry.refresh_availability(
      route_credential_fn: route_credential_fn(credential_opts)
    )

    :ok
  catch
    :exit, _reason -> :ok
  end

  @spec inference_route_registry(keyword()) :: GenServer.server()
  defp inference_route_registry(resolver_opts),
    do: Keyword.get(resolver_opts, :inference_routes, MingaAgent.InferenceRouteRegistry)

  @spec route_credential_fn(keyword()) ::
          (String.t() ->
             {:ok, MingaAgent.InferenceRoute.route_credential()} | {:error, String.t()})
  defp route_credential_fn(credential_opts) do
    fn route_id ->
      case MingaAgent.Credentials.route_credential(route_id, credential_opts) do
        {:ok, credential} -> {:ok, credential}
        {:error, {:route_unavailable, remedy}} -> {:error, remedy}
      end
    end
  end

  @doc """
  Lists registered model routes that declare a setup action. Runs in the calling worker.

  Returns `{:error, :unsupported}` when the session's backend cannot run contributed routes.
  """
  @spec inference_route_setups(GenServer.server()) ::
          {:ok, [MingaAgent.InferenceRouteRegistry.Entry.t()]} | {:error, :unsupported}
  def inference_route_setups(session) do
    with {:ok, registry, _credential_opts} <- GenServer.call(session, :inference_route_context) do
      {:ok,
       registry |> MingaAgent.InferenceRouteRegistry.list() |> Enum.filter(& &1.spec.setup_action)}
    end
  catch
    :exit, _reason -> {:ok, []}
  end

  @doc """
  Runs one route's availability check in the calling worker, never in the Session or Editor process, and returns its refreshed registration.
  """
  @spec check_inference_route(GenServer.server(), String.t()) ::
          {:ok, MingaAgent.InferenceRouteRegistry.Entry.t()} | {:error, :unsupported | :not_found}
  def check_inference_route(session, route_id) when is_binary(route_id) do
    with {:ok, registry, credential_opts} <- GenServer.call(session, :inference_route_context) do
      registry
      |> MingaAgent.InferenceRouteRegistry.refresh_availability(
        route_ids: [route_id],
        route_credential_fn: route_credential_fn(credential_opts)
      )
      |> Enum.find(&(&1.spec.id == route_id))
      |> case do
        nil -> {:error, :not_found}
        entry -> {:ok, entry}
      end
    end
  catch
    :exit, _reason -> {:error, :not_found}
  end

  @spec fetch_codex_models(ModelSelection.Credential.OAuth.t() | nil, keyword()) ::
          CodexModels.result()
  defp fetch_codex_models(nil, _opts), do: {:error, :not_loaded}
  defp fetch_codex_models(credential, opts), do: CodexModels.fetch(credential, opts)

  @doc "Checks discovery publication without calling the Session process."
  @spec model_discovery_current?(pid(), :atomics.atomics_ref()) :: boolean()
  def model_discovery_current?(session, validity) do
    Process.alive?(session) and :atomics.get(validity, 1) == 1
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

  Apple availability runs in the calling process on the Session host. Use a
  worker if the caller must remain responsive. Pass a larger `timeout` when
  slow provider startup should not surface as a call timeout.
  """
  @spec set_model(GenServer.server(), ModelResolver.intent(), timeout()) ::
          :ok | {:error, term()}
  def set_model(session, model, timeout \\ 5_000) do
    request_model_change(session, {:set_model, model}, timeout)
  end

  @doc "Changes a model only while its captured conversation and selection epoch remain current."
  @spec set_model_for_target(
          GenServer.server(),
          ConnectionTarget.t(),
          ModelResolver.intent(),
          timeout()
        ) ::
          :ok | {:error, term()}
  def set_model_for_target(session, target, intent, timeout \\ 5_000) do
    request_model_change(session, {:set_model_for_target, target, intent}, timeout)
  end

  @spec request_model_change(GenServer.server(), tuple(), timeout()) :: :ok | {:error, term()}
  defp request_model_change(session, request, timeout) do
    case GenServer.call(session, request, timeout) do
      {:check_apple, ref, host, opts} ->
        readiness = probe_apple_for_selection(host, opts, timeout)
        GenServer.call(session, {:finish_apple_model_selection, ref, readiness}, timeout)

      result ->
        result
    end
  end

  @spec probe_apple_for_selection(node(), keyword(), timeout()) ::
          ModelResolver.apple_availability()
  defp probe_apple_for_selection(host, opts, _timeout) when host == node(),
    do: ModelResolver.apple_availability(opts)

  defp probe_apple_for_selection(host, opts, timeout) do
    :erpc.call(host, ModelResolver, :apple_availability, [opts], timeout)
  catch
    :error, {:erpc, _reason} -> {:error, :probe_failed}
  end

  @doc "Toggles the collapsed state of a tool or thinking message by stable transcript ID."
  @spec toggle_tool_collapse(GenServer.server(), non_neg_integer()) :: :ok
  def toggle_tool_collapse(session, message_id) do
    GenServer.call(session, {:toggle_tool_collapse, message_id})
  end

  @doc "Toggles all tool call messages between collapsed and expanded."
  @spec toggle_all_tool_collapses(GenServer.server()) :: :ok
  def toggle_all_tool_collapses(session) do
    GenServer.call(session, :toggle_all_tool_collapses)
  end

  @doc "Branches the conversation at the given turn index."
  @spec branch_at(GenServer.server(), non_neg_integer()) :: {:ok, String.t()} | {:error, term()}
  def branch_at(session, turn_index) when is_integer(turn_index) do
    GenServer.call(session, {:branch_at, turn_index})
  end

  @doc "Lists all conversation branches."
  @spec list_branches(GenServer.server()) :: {:ok, String.t()}
  def list_branches(session) do
    GenServer.call(session, :list_branches)
  end

  @doc "Switches to a named branch, replacing the current messages."
  @spec switch_branch(GenServer.server(), non_neg_integer()) :: :ok | {:error, term()}
  def switch_branch(session, branch_index) when is_integer(branch_index) do
    GenServer.call(session, {:switch_branch, branch_index})
  end

  @doc "Appends a system message to the conversation and notifies subscribers."
  @spec add_system_message(GenServer.server(), String.t(), Message.system_level()) :: :ok
  def add_system_message(session, text, level \\ :info) do
    GenServer.cast(session, {:add_system_message, text, level})
  end

  @doc "Appends a system message only when the session still has the expected identity."
  @spec add_system_message_for_id(
          GenServer.server(),
          String.t(),
          String.t(),
          Message.system_level()
        ) :: :ok
  def add_system_message_for_id(session, expected_session_id, text, level) do
    GenServer.cast(session, {:add_system_message_for_id, expected_session_id, text, level})
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

  @type queue_target :: {record_id :: String.t(), request_id :: String.t(), pos_integer()}
  @type queue_draft :: {non_neg_integer(), String.t(), [DraftAttachment.identity()], String.t()}

  @doc "Returns the exact active turn and queue fence for a saved composer to display."
  @spec queue_target(GenServer.server(), String.t()) ::
          {:ok, queue_target()} | {:error, :not_persistent | :stale_target | :turn_not_active}
  def queue_target(session, record_id), do: GenServer.call(session, {:queue_target, record_id})

  @doc "Consumes the exact saved draft only when this displayed turn accepts the queued submission."
  @spec submit_queued_draft(
          GenServer.server(),
          queue_target(),
          TurnExecution.prompt_kind(),
          queue_draft(),
          TurnExecution.content()
        ) :: {:ok, TurnExecution.queue_receipt()} | {:error, term()}
  def submit_queued_draft(session, target, kind, draft, content) do
    GenServer.call(session, {:submit_queued_draft, target, kind, draft, content}, 30_000)
  end

  @doc "Returns bounded previews of pending input for the original local saved conversation."
  @spec queued_input_summaries(GenServer.server(), String.t()) ::
          {:ok, [QueuedInputSummary.t()]} | {:error, term()}
  def queued_input_summaries(session, record_id) do
    GenServer.call(session, {:queued_input_summaries, record_id})
  end

  @doc "Reads the editable text of one exact pending revision in the local saved Session."
  @spec queued_input_text(GenServer.server(), String.t(), QueuedInputSummary.identity()) ::
          {:ok, String.t()} | {:error, term()}
  def queued_input_text(session, record_id, identity) do
    GenServer.call(session, {:queued_input_text, record_id, identity})
  end

  @doc "Edits or removes only the displayed pending entry in the original saved Session."
  @spec change_queued_input(
          GenServer.server(),
          String.t(),
          {pos_integer(), pos_integer()},
          TurnExecution.queued_edit()
        ) :: :ok | {:error, term()}
  def change_queued_input(session, record_id, identity, operation) do
    GenServer.call(session, {:change_queued_input, record_id, identity, operation}, 30_000)
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
  Returns and clears the volatile queue. A saved Session requires a draft recall transaction.
  """
  @spec recall_queues(GenServer.server()) ::
          {[String.t() | [ReqLLM.Message.ContentPart.t()]],
           [String.t() | [ReqLLM.Message.ContentPart.t()]]}
          | {:error, :saved_draft_required}
  def recall_queues(session) do
    GenServer.call(session, :recall_queues)
  end

  @doc "Recalls volatile queued input asynchronously for an exact local conversation."
  @spec request_volatile_queue_recall(pid(), reference(), pos_integer()) :: :ok
  def request_volatile_queue_recall(session, conversation, workspace)
      when node(session) == node() and is_reference(conversation) do
    GenServer.cast(session, {:recall_volatile_queue, self(), conversation, workspace})
  end

  @doc "Clears both queues without returning their contents."
  @spec clear_queues(GenServer.server()) :: :ok | {:error, term()}
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

  @doc "Combines queued input for the provider without flattening captured content to display text."
  @spec combine_queued_prompts([TurnExecution.content()]) :: TurnExecution.content()
  def combine_queued_prompts([content]), do: content

  def combine_queued_prompts(entries) do
    if Enum.all?(entries, &is_binary/1) do
      entries |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")
    else
      entries |> Enum.reduce([], &prepend_queued_content/2) |> Enum.reverse()
    end
  end

  @spec prepend_queued_content(TurnExecution.content(), [ReqLLM.Message.ContentPart.t()]) ::
          [ReqLLM.Message.ContentPart.t()]
  defp prepend_queued_content("", acc), do: acc
  defp prepend_queued_content([], acc), do: acc

  defp prepend_queued_content(text, acc) when is_binary(text),
    do: [ReqLLM.Message.ContentPart.text(text) | separate_queued_content(acc)]

  defp prepend_queued_content(parts, acc),
    do: Enum.reverse(parts, separate_queued_content(acc))

  @spec separate_queued_content([ReqLLM.Message.ContentPart.t()]) :: [
          ReqLLM.Message.ContentPart.t()
        ]
  defp separate_queued_content([]), do: []
  defp separate_queued_content(acc), do: [ReqLLM.Message.ContentPart.text("\n\n") | acc]

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

    credentials_configured_fn = Keyword.get(opts, :credentials_configured_fn)
    credential_opts = Keyword.get(provider_opts, :credential_opts, [])

    credentials_snapshot_fn =
      Keyword.get(opts, :credentials_snapshot_fn, fn -> Credentials.snapshot(credential_opts) end)

    initial_thinking_level =
      Keyword.get(opts, :thinking_level, Keyword.get(provider_opts, :thinking_level))

    timestamp = Calendar.strftime(DateTime.utc_now(), "%H:%M:%S UTC")

    session_id = Keyword.get(opts, :session_id, generate_session_id())
    raw_model_name = session_model_name(opts, provider_opts)
    resolved_provider_resolution = resolve_provider(opts)
    credential_snapshot = credentials_snapshot_fn.()

    {model_selection, resolution_problem} =
      initial_model_selection(
        resolved_provider_resolution,
        raw_model_name,
        provider_opts,
        credential_snapshot,
        initial_thinking_level
      )

    credentials_configured? =
      initial_credentials_configured?(
        resolved_provider_resolution.module,
        model_selection,
        provider_opts,
        credential_snapshot,
        credentials_configured_fn
      )

    provider_resolution =
      if credentials_configured?,
        do: resolved_provider_resolution,
        else: unconfigured_provider_resolution()

    provider_module = provider_resolution.module
    model_name = selection_model_name(model_selection, raw_model_name)

    {provider_name, provider_opts} =
      session_provider_configuration(provider_module, model_name, provider_opts)

    provider_name =
      case model_selection do
        %ModelSelection{route: %{model_provider: selected_provider}} -> selected_provider
        nil -> provider_name
      end

    provider_opts = maybe_put_model_selection(provider_opts, model_selection)

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

    credential_readiness = if(credentials_configured?, do: :configured, else: :unconfigured)

    state = %{
      session_id: session_id,
      custom_title: nil,
      archived?: false,
      artifact_runtime: Keyword.get(opts, :artifact_runtime),
      workdir: Keyword.get(opts, :workdir),
      event_log_server: Keyword.get(opts, :event_log_server, EventLog),
      event_log_failure: nil,
      provider: provider,
      credentials_configured_fn: credentials_configured_fn,
      credentials_snapshot_fn: credentials_snapshot_fn,
      credential_readiness: credential_readiness,
      connection: Connection.new(resolution_problem),
      turn_execution: TurnExecution.new(),
      transcript:
        Transcript.new(
          [Message.system(initial_system_message(timestamp, Keyword.get(opts, :startup_notice)))],
          now,
          make_ref()
        ),
      continuation: Continuation.new(),
      checklist: Checklist.new(),
      checklist_archive: ChecklistArchive.new(),
      file_changes: [],
      subscriber_lifecycle: SubscriberLifecycle.new(),
      tool_approval_policy: Keyword.get(opts, :tool_approval_policy, :interactive),
      tool_authority: %{
        options: Keyword.get(opts, :options_server, Options),
        registry: Keyword.get(provider_opts, :tool_registry, ToolRegistry),
        read_only?: Keyword.get(provider_opts, :read_only?, false),
        revision: make_ref(),
        invocations: %{}
      },
      idle_gc_timeout_ms: Keyword.get_lazy(opts, :idle_gc_timeout_ms, &idle_gc_timeout_ms/0),
      persistence: Persistence.new(Keyword.get(opts, :persist?, true)),
      model_selection: model_selection,
      unresolved_route: nil,
      model_discovery: nil,
      model_discovery_request: nil,
      apple_selection_probe: nil,
      pending_model_change: nil,
      pending_thinking_level: if(model_selection, do: nil, else: initial_thinking_level),
      notifier: Keyword.get(opts, :notifier, Notifier),
      background_subagent: Keyword.get(opts, :background_subagent, false),
      hooks_enabled?: Keyword.get(opts, :hooks_enabled?, true),
      session_start_hook_enabled?:
        Keyword.get(opts, :session_start_hook_enabled?, Keyword.get(opts, :hooks_enabled?, true)),
      hook_task_supervisor: Keyword.get(opts, :hook_task_supervisor, Minga.Eval.TaskSupervisor),
      session_store_dir: Keyword.get(opts, :session_store_dir),
      session_manager: Keyword.get(opts, :session_manager),
      created_at: now,
      credentials_configured: credentials_configured?,
      job_owner: nil,
      job_owner_ref: nil,
      job_epoch: 0,
      job_ledger: JobLedger.new(),
      job_admissions: %{}
    }

    state = maybe_start_job_owner(state, Keyword.get(opts, :start_job_owner?, true))

    maybe_mark_interrupted_work(state, Keyword.get(opts, :recover_interrupted_work?, true))

    record_critical_event(state, :session_started, %{
      model: state.provider.model_name,
      provider: state.provider.provider_name,
      background_subagent: state.background_subagent
    })

    # Initial subscribers attach before provider start is queued, so their first
    # events are this start's acknowledgement and connection, never a reply that
    # waits behind provider start or SessionStart hooks.
    state =
      subscribe_initial(
        state,
        Keyword.get(opts, :subscribers, []),
        Keyword.get(opts, :start_token)
      )

    # Start configured providers asynchronously; unconfigured sessions retain drafts.
    if credentials_configured? do
      send(self(), :start_provider)
    end

    {:ok, maybe_schedule_idle_gc(state)}
  end

  @impl GenServer
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call({:seed_messages, messages}, _from, state) do
    case model_seed_messages(messages) do
      {:ok, model_messages} -> reply_to_seed_messages(state, messages, model_messages)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
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

  def handle_call(
        {:send_idle_composer, record_id, content},
        {caller, _tag},
        %{session_id: record_id} = state
      )
      when node(caller) == node() and is_binary(record_id) and
             (is_binary(content) or is_list(content)) do
    if TurnExecution.active?(state.turn_execution) do
      {:reply, {:error, :queue_target_unavailable}, state}
    else
      handle_prompt(content, :steering, state)
    end
  end

  def handle_call({:send_idle_composer, _record, _content}, _from, state),
    do: {:reply, {:error, :stale_target}, state}

  def handle_call(
        {:send_prompt_for_id, expected_session_id, _content},
        _from,
        %{session_id: current_session_id} = state
      )
      when expected_session_id != current_session_id do
    {:reply, {:error, :session_id_changed}, state}
  end

  def handle_call(
        {:send_prompt_for_id, session_id, content},
        _from,
        %{session_id: session_id} = state
      ) do
    handle_prompt(content, :steering, state)
  end

  def handle_call({:send_attached_prompt, record_id, shown, content}, {caller, _tag}, state)
      when node(caller) == node() do
    handle_attached_prompt(state, record_id, shown, content)
  end

  def handle_call({:send_attached_prompt, _record_id, _shown, _content}, _from, state),
    do: {:reply, {:error, :stale_target}, state}

  def handle_call({:submit_queued_draft, target, kind, draft, content}, {caller, _tag}, state)
      when node(caller) == node() do
    handle_queued_draft(state, target, kind, draft, content)
  end

  def handle_call({:submit_queued_draft, _target, _kind, _draft, _content}, _from, state),
    do: {:reply, {:error, :stale_target}, state}

  def handle_call({:queue_target, record_id}, {caller, _tag}, state) when node(caller) == node(),
    do: {:reply, queue_target_for_record(state, record_id), state}

  def handle_call({:queue_target, _record_id}, _from, state),
    do: {:reply, {:error, :stale_target}, state}

  def handle_call({:queued_input_summaries, record_id}, {caller, _tag}, state)
      when node(caller) == node() and is_binary(record_id) do
    case validate_composer_record(state, record_id) do
      :ok -> {:reply, {:ok, pending_input_summaries(state.turn_execution)}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:queued_input_summaries, _record_id}, _from, state),
    do: {:reply, {:error, :stale_target}, state}

  def handle_call({:queued_input_text, record_id, identity}, {caller, _tag}, state)
      when node(caller) == node() and is_binary(record_id) do
    {:reply, queued_input_text_result(state, record_id, identity), state}
  end

  def handle_call({:queued_input_text, _record_id, _identity}, _from, state),
    do: {:reply, {:error, :stale_target}, state}

  def handle_call(
        {:change_queued_input, record_id, {id, revision}, operation},
        {caller, _tag},
        state
      )
      when node(caller) == node() and is_binary(record_id) and is_integer(id) and id > 0 and
             is_integer(revision) and revision > 0 do
    change_queued_input_reply(state, record_id, id, revision, operation)
  end

  def handle_call({:change_queued_input, _record_id, _identity, _operation}, _from, state),
    do: {:reply, {:error, :stale_target}, state}

  def handle_call({:read_draft_attachment, record_id, identity}, {caller, _tag}, state)
      when node(caller) == node() do
    {:reply, inspect_composer_attachment(state, record_id, identity), state}
  end

  def handle_call({:read_draft_attachment, _record_id, _identity}, _from, state),
    do: {:reply, {:error, :stale_target}, state}

  def handle_call(
        {:remote_composer, record_id, {_driver, _receipt} = authority, operation},
        {caller, _tag},
        state
      )
      when node(caller) == node() do
    with true <- SubscriberLifecycle.question_driver?(state.subscriber_lifecycle, authority),
         :ok <- validate_composer_record(state, record_id) do
      handle_remote_composer(state, record_id, operation)
    else
      false -> {:reply, {:error, :not_driver}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  catch
    class, _private_reason ->
      reason = {:remote_composer_failed, class}
      {:stop, reason, {:error, {:remote_unavailable, reason}}, state}
  end

  def handle_call({:remote_composer, _record_id, _authority, _operation}, _from, state),
    do: {:reply, {:error, :not_driver}, state}

  def handle_call(
        {:abort_for_id, expected_session_id},
        _from,
        %{session_id: current_session_id} = state
      )
      when expected_session_id != current_session_id do
    {:reply, {:error, :session_id_changed}, state}
  end

  def handle_call(
        {:abort_for_id, _expected_session_id},
        _from,
        %{provider: provider} = state
      )
      when ProviderLifecycle.is_detached(provider) do
    {:reply, :ok, state}
  end

  def handle_call({:abort_for_id, _expected_session_id}, _from, state) do
    {:reply, :ok, abort_turn(state)}
  end

  def handle_call(
        {:abort_for_id, expected_session_id, _request_id},
        _from,
        %{session_id: current_session_id} = state
      )
      when expected_session_id != current_session_id do
    {:reply, {:error, :session_id_changed}, state}
  end

  def handle_call({:abort_for_id, session_id, request_id}, _from, state) do
    case active_turn_target(state) do
      {^session_id, ^request_id} -> {:reply, :ok, abort_turn(state)}
      _other -> {:reply, {:error, :stale_turn}, state}
    end
  end

  def handle_call({:stop_turn, {_, _} = target}, _from, state) do
    case active_turn_target(state) do
      ^target -> stop_active_turn(state)
      _ -> {:reply, {:error, :stale_turn}, state}
    end
  end

  def handle_call({:stop_turn, _target}, _from, state),
    do: {:reply, {:error, :stale_turn}, state}

  def handle_call({:send_follow_up, content}, _from, state) do
    handle_prompt(content, :follow_up, state)
  end

  def handle_call(:recall_queues, _from, state) do
    if Persistence.enabled?(state.persistence) do
      {:reply, {:error, :saved_draft_required}, state}
    else
      {queues, execution} = TurnExecution.recall_queues(state.turn_execution)
      {:reply, queues, broadcast(%{state | turn_execution: execution}, :queues_recalled)}
    end
  end

  def handle_call(:clear_queues, _from, state) do
    candidate = %{state | turn_execution: TurnExecution.clear_queues(state.turn_execution)}

    case commit_effect_snapshot(state, candidate) do
      {:ok, committed} -> {:reply, :ok, broadcast(committed, :queues_recalled)}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(:get_queued_messages, _from, state) do
    {:reply, TurnExecution.queues(state.turn_execution), state}
  end

  def handle_call({:set_boundary, path, start_line, end_line}, _from, state) do
    case TurnExecution.set_boundary(state.turn_execution, path, start_line, end_line) do
      {:ok, execution} -> {:reply, :ok, revise_tool_policy(state, execution)}
      {:error, _message} = error -> {:reply, error, state}
    end
  end

  def handle_call({:clear_boundary, path}, _from, state) do
    execution = TurnExecution.clear_boundary(state.turn_execution, path)
    {:reply, :ok, revise_tool_policy(state, execution)}
  end

  def handle_call(:clear_all_boundaries, _from, state) do
    execution = TurnExecution.clear_boundaries(state.turn_execution)
    {:reply, :ok, revise_tool_policy(state, execution)}
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
    session_id = generate_session_id()

    case reserve_session_identity(state, session_id) do
      {:ok, reservation} ->
        case commit_session_identity(state, reservation) do
          :ok ->
            {:reply, :ok, reset_new_session(state, session_id)}

          {:error, reason} ->
            abort_session_identity(state, reservation)
            {:reply, {:error, {:session_identity_commit_failed, reason}}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:session_id, _from, state) do
    {:reply, state.session_id, state}
  end

  def handle_call({:admit_job, _spec}, _from, %{job_owner: nil} = state),
    do: {:reply, {:error, :no_job_owner}, state}

  def handle_call({:admit_job, spec}, {caller, _tag}, state) do
    case JobLedger.admit(state.job_ledger, spec, state.job_epoch, DateTime.utc_now()) do
      {:ok, record, ledger} ->
        # The caller's exit cancels the job until a background job starts or a foreground job ends.
        admissions = Map.put(state.job_admissions, Process.monitor(caller), record.id)

        {:reply, {:ok, record, state.job_owner},
         schedule_save(%{state | job_ledger: ledger, job_admissions: admissions})}

      {:error, _limit} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:job, job_id}, _from, state),
    do: {:reply, JobLedger.fetch(state.job_ledger, job_id), state}

  def handle_call(:jobs, _from, state), do: {:reply, JobLedger.list(state.job_ledger), state}

  def handle_call({:cancel_job, job_id}, _from, state) do
    case JobLedger.fetch(state.job_ledger, job_id) do
      {:ok, %JobRecord{status: :running}} -> {:reply, cancel_owned_job(state, job_id), state}
      {:ok, %JobRecord{}} -> {:reply, {:error, :already_terminal}, state}
      {:error, :job_not_found} = error -> {:reply, error, state}
    end
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

  def handle_call({:load_session, _id, origin_id}, _from, state)
      when is_binary(origin_id) and origin_id != state.session_id,
      do: {:reply, {:error, :stale_session}, state}

  def handle_call({:load_session, session_id, _origin_id}, from, state) do
    case SessionStore.load_recoverable(
           session_id,
           state.session_store_dir,
           artifact_store_opts(state)
         ) do
      {:ok, :draft_only} -> restore_draft_only_session(state, session_id)
      {:ok, data} -> begin_loaded_session_restore(state, data, from)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:import_legacy_session, _id, origin_id}, _from, state)
      when is_binary(origin_id) and origin_id != state.session_id,
      do: {:reply, {:error, :stale_session}, state}

  def handle_call({:import_legacy_session, session_id, _origin_id}, from, state) do
    case SessionStore.load_legacy(session_id, state.session_store_dir) do
      {:ok, legacy_data} -> persist_legacy_import(state, session_id, legacy_data, from)
      {:error, reason} -> {:reply, {:error, reason}, state}
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

  def handle_call({:transcript_since, cursor}, _from, state) do
    {:reply, Transcript.since(state.transcript, cursor), state}
  end

  def handle_call({:editor_transcript, cursor}, _from, state) do
    {:reply, editor_arrival_transcript(state.transcript, state.file_changes, cursor), state}
  end

  def handle_call({:editor_arrival, cursor, subscriber, arrival}, _from, state)
      when is_pid(subscriber) and node(subscriber) == node() and is_reference(arrival) do
    case SubscriberLifecycle.role(state.subscriber_lifecycle, subscriber) do
      nil ->
        {:reply, {:error, :unsubscribed}, state}

      _role ->
        snapshot = editor_snapshot_from_state(state)
        transcript = editor_arrival_transcript(state.transcript, state.file_changes, cursor)

        send(
          subscriber,
          {:agent_event, self(), {:editor_arrival_ready, arrival, {snapshot, transcript}}}
        )

        {:reply, :forwarded, state}
    end
  end

  def handle_call({:retained_output_store, target, id, reference}, _from, state) do
    result =
      with :ok <- validate_connection_target(state, target),
           {:ok, ^reference} <- Transcript.retained_output(state.transcript, id, reference),
           do: ensure_artifact_store(state)

    {:reply, result, state}
  end

  def handle_call({:cumulative_file_change, target, path}, _from, state) do
    result =
      with :ok <- validate_connection_target(state, target),
           {:ok, before_side, after_side} <- FileChange.cumulative_sides(state.file_changes, path),
           {:ok, store} <- ensure_artifact_store(state) do
        {:ok, store, before_side, after_side}
      end

    {:reply, result, state}
  end

  def handle_call(
        {:apply_review_mutation, target, view, path, source, revision, operation},
        _from,
        state
      ) do
    result =
      with :ok <- validate_connection_target(state, target),
           {:ok, _receipt} <-
             MingaAgent.ProjectView.Overlay.conditional_review_mutate(
               view,
               path,
               source,
               revision,
               operation
             ) do
        :ok
      end

    {:reply, result, state}
  end

  def handle_call({:changed_file_counts, target}, _from, state) do
    case validate_connection_target(state, target) do
      :ok -> {:reply, {:ok, FileChange.changed_file_counts(state.file_changes)}, state}
      {:error, :stale_target} = error -> {:reply, error, state}
    end
  end

  def handle_call(
        {:transcript_history_before, %ConnectionTarget{} = target, anchor, limit},
        _from,
        state
      ) do
    case validate_connection_target(state, target) do
      :ok ->
        cursor = Transcript.cursor(state.transcript)
        {:reply, Transcript.history_before(state.transcript, cursor, anchor, limit), state}

      {:error, :stale_target} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:transcript_history_before, cursor, anchor, limit}, _from, state) do
    {:reply, Transcript.history_before(state.transcript, cursor, anchor, limit), state}
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
    {:reply, editor_snapshot_from_state(state), state}
  end

  def handle_call({:begin_connection, target, method, owner, notify}, _from, state) do
    begin_connection_workflow(state, target, method, owner, notify)
  end

  def handle_call({:register_connection_worker, target, ref, worker}, {caller, _}, state) do
    register_connection_worker_workflow(state, target, ref, worker, caller)
  end

  def handle_call({:cancel_connection, target, ref}, {caller, _}, state) do
    cancel_connection_workflow(state, target, ref, caller)
  end

  def handle_call({:commit_api_key, target, ref, provider, secret}, {caller, _}, state) do
    commit_api_key_workflow(state, target, ref, provider, secret, caller)
  end

  def handle_call({:commit_oauth, target, ref, secret}, {caller, _}, state) do
    commit_oauth_workflow(state, target, ref, secret, caller)
  end

  def handle_call({:retry_connection, target}, _from, state) do
    retry_connection_workflow(state, target)
  end

  def handle_call(:artifact_store, _from, state) do
    {:reply, ensure_artifact_store(state), state}
  end

  def handle_call({:rename_conversation, target, title}, {caller, _tag}, state)
      when node(caller) == node() do
    case rename_saved_conversation(state, target, title) do
      {:ok, title} -> {:reply, {:ok, title}, %{state | custom_title: title}}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:rename_conversation, _target, _title}, _from, state),
    do: {:reply, {:error, :unsupported_session}, state}

  def handle_call({:set_archived, target, archived?}, {caller, _tag}, state)
      when node(caller) == node() and is_boolean(archived?) do
    case set_saved_archive_status(state, target, archived?) do
      :ok -> {:reply, :ok, %{state | archived?: archived?}}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:set_archived, _target, _archived?}, _from, state),
    do: {:reply, {:error, :unsupported_session}, state}

  def handle_call(:metadata, _from, state) do
    messages = Transcript.messages(state.transcript)
    first_prompt = first_user_prompt(messages)

    title =
      state.custom_title ||
        readable_title(first_assistant_text(messages)) ||
        readable_title(first_prompt)

    meta = %SessionMetadata{
      id: state.session_id,
      title: title,
      archived?: state.archived?,
      model_name: state.provider.model_name,
      provider_name: state.provider.provider_name,
      created_at: state.created_at,
      last_message_at: Transcript.last_changed_at(state.transcript),
      message_count: length(messages),
      turn_count: SessionMetadata.turn_count(messages),
      first_prompt: first_prompt,
      cost: Transcript.usage(state.transcript).cost,
      status: TurnExecution.status(state.turn_execution),
      workdir: state.workdir,
      active_request_id: active_turn_request_id(state)
    }

    {:reply, meta, state}
  end

  def handle_call({:respond_to_approval_as, client_pid, target, decision}, _from, state) do
    if driver_allowed?(state, client_pid) do
      handle_approval_response(target, decision, state)
    else
      {:reply, {:error, :not_driver}, state}
    end
  end

  def handle_call({:respond_to_approval, target, decision}, _from, state) do
    handle_approval_response(target, decision, state)
  end

  def handle_call(:pending_question, _from, state) do
    {:reply, public_question(state.turn_execution), state}
  end

  def handle_call({:respond_to_question_as, authority, target, response}, _from, state) do
    if SubscriberLifecycle.question_driver?(state.subscriber_lifecycle, authority) do
      respond_to_question(state, target, response)
    else
      {:reply, {:error, :not_driver}, state}
    end
  end

  def handle_call({:set_tool_trust, name, scope}, _from, state) do
    execution = TurnExecution.put_trust(state.turn_execution, name, scope)
    {:reply, :ok, revise_tool_policy(state, execution)}
  end

  def handle_call(:restart_provider, _from, state) do
    restart_provider_workflow(state)
  end

  def handle_call({:revoke_tool_trust, :all}, _from, state) do
    execution = TurnExecution.revoke_trust(state.turn_execution, :all)
    {:reply, :ok, revise_tool_policy(state, execution)}
  end

  def handle_call({:revoke_tool_trust, name}, _from, state) do
    execution = TurnExecution.revoke_trust(state.turn_execution, name)
    {:reply, :ok, revise_tool_policy(state, execution)}
  end

  def handle_call(:list_tool_trust, _from, state) do
    {:reply, TurnExecution.trust_levels(state.turn_execution), state}
  end

  def handle_call({:subscribe, pid, opts}, _from, state) do
    role = Keyword.get(opts, :role, SubscriberLifecycle.default_role(state.subscriber_lifecycle))

    case reply_to_subscribe(state, pid, role, Keyword.get(opts, :questions?, false) == true) do
      {:reply, {:ok, _attachment}, subscribed} -> {:reply, :ok, subscribed}
      {:reply, {:error, _reason}, _state} = error -> error
    end
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

  def handle_call({:broker_attach, pid, role, questions?}, _from, state) do
    mode = if questions?, do: :remote, else: false
    reply_to_subscribe(state, pid, role, mode)
  end

  def handle_call({:rollback_broker_attach, pid, ref}, _from, state) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, handle_subscriber_down(state, pid, ref, :attach_failed)}
  end

  def handle_call({:broker_detach, authority}, _from, state) do
    case SubscriberLifecycle.authorize_broker_detach(state.subscriber_lifecycle, authority) do
      {:ok, pid} -> {:reply, :ok, detach_subscriber(state, pid, :detached)}
      {:error, :not_driver} = error -> {:reply, error, state}
    end
  end

  def handle_call(
        :compact,
        _from,
        %{continuation: %Continuation{tool_checkpoint: %{}}} = state
      ),
      do: {:reply, {:error, :effect_reconciliation_required}, state}

  def handle_call(:compact, _from, %{provider: provider} = state)
      when ProviderLifecycle.is_detached(provider) do
    {:reply, {:error, "No active provider"}, state}
  end

  def handle_call(:compact, _from, state) do
    if function_exported?(state.provider.module, :compact, 2) do
      result =
        state.provider.module.compact(
          ProviderLifecycle.pid(state.provider),
          state.continuation.messages
        )

      reply_to_compact(state, result)
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
    case refresh_continuation_prefix(state, {:activate, name}) do
      {:ok, updated, result} -> {:reply, result, updated}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
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
    case refresh_continuation_prefix(state, {:deactivate, name}) do
      {:ok, updated, result} -> {:reply, result, updated}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
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

    result =
      case result do
        {:ok, available, active} -> {:ok, available, selected_skill_names(state, active)}
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call(:model_selection, _from, state) do
    {:reply, state.model_selection, state}
  end

  def handle_call(:begin_model_discovery, _from, state)
      when state.provider.module == MingaAgent.Providers.Native do
    credential = state.credentials_snapshot_fn.().oauth_ref
    ref = make_ref()
    credential_opts = Keyword.get(state.provider.opts, :credential_opts, [])
    resolver_opts = Keyword.get(state.provider.opts, :model_resolver_opts, [])

    {:reply, {:native, ref, credential, credential_opts, resolver_opts},
     %{state | model_discovery_request: ref}}
  end

  def handle_call(:begin_model_discovery, _from, state), do: {:reply, :local, state}

  def handle_call(:inference_route_context, _from, state)
      when state.provider.module == MingaAgent.Providers.Native do
    resolver_opts = Keyword.get(state.provider.opts, :model_resolver_opts, [])
    credential_opts = Keyword.get(state.provider.opts, :credential_opts, [])
    {:reply, {:ok, inference_route_registry(resolver_opts), credential_opts}, state}
  end

  def handle_call(:inference_route_context, _from, state),
    do: {:reply, {:error, :unsupported}, state}

  def handle_call(
        {:finish_model_discovery, ref, credential, codex, apple},
        _from,
        %{model_discovery_request: ref} = state
      )
      when is_reference(ref) do
    snapshot = state.credentials_snapshot_fn.()

    if credential == snapshot.oauth_ref do
      state = invalidate_model_discovery(state)
      validity = :atomics.new(1, [])
      :atomics.put(validity, 1, 1)
      state = %{state | model_discovery: {validity, codex, apple}}

      notice = model_discovery_notice(credential, codex, apple, state.model_selection)
      candidates = discovered_model_candidates(state, snapshot)
      {:reply, {:ok, candidates, notice, validity}, state}
    else
      {:reply, local_model_discovery(state, snapshot), invalidate_model_discovery(state)}
    end
  end

  def handle_call({:finish_model_discovery, _ref, _credential, _codex, _apple}, _from, state) do
    {:reply, local_model_discovery(state, state.credentials_snapshot_fn.()), state}
  end

  def handle_call(:get_available_models, _from, state)
      when state.provider.module == MingaAgent.Providers.Native do
    {:reply, {:ok, discovered_model_candidates(state, state.credentials_snapshot_fn.())}, state}
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
        {:set_thinking_level, level},
        _from,
        %{model_selection: %ModelSelection{}} = state
      ) do
    with {:ok, selection} <- ModelSelection.with_reasoning(state.model_selection, level),
         {:ok, updated} <- apply_resolved_model_selection(state, selection) do
      {:reply, :ok, updated}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
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

  def handle_call(:cycle_thinking_level, _from, %{model_selection: %ModelSelection{}} = state) do
    options = state.model_selection.policy.reasoning.options
    current_effort = state.model_selection.policy.reasoning.effort
    current = Enum.find_index(options, &(&1 == current_effort)) || 0
    level = Enum.at(options, rem(current + 1, length(options)))

    with {:ok, selection} <- ModelSelection.with_reasoning(state.model_selection, level),
         {:ok, updated} <- apply_resolved_model_selection(state, selection) do
      {:reply, {:ok, %{"level" => level}}, updated}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
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
        %{provider: %{module: MingaAgent.Providers.Native}} = state
      ) do
    snapshot = state.credentials_snapshot_fn.()
    candidates = discovered_model_candidates(state, snapshot, false)

    case next_model_candidate(candidates) do
      %ModelCandidate{selection: selection} ->
        case apply_resolved_model_selection(state, selection) do
          {:ok, state} ->
            reply = %{
              "model" => selection.route.display_name,
              "provider" => selection.route.model_provider,
              "route" => selection.route.execution.wire_protocol
            }

            {:reply, {:ok, reply}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      nil ->
        {:reply, {:error, :no_available_model}, state}
    end
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

  def handle_call({:set_model, intent}, {caller, _tag}, state) do
    set_model_workflow(state, intent, caller)
  end

  def handle_call({:set_model_for_target, target, intent}, {caller, _tag}, state) do
    case validate_connection_target(state, target) do
      :ok -> set_model_workflow(state, intent, caller)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:finish_apple_model_selection, ref, readiness},
        {caller, _tag},
        %{apple_selection_probe: {ref, caller, target, intent}} = state
      ) do
    state = %{state | apple_selection_probe: nil}

    case validate_connection_target(state, target) do
      :ok -> finish_apple_model_selection(state, intent, readiness)
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:finish_apple_model_selection, _ref, _readiness}, _from, state),
    do: {:reply, {:error, :stale_target}, state}

  def handle_call({:toggle_tool_collapse, message_id}, _from, state) do
    transcript = Transcript.toggle_message_collapse(state.transcript, message_id)

    if transcript == state.transcript do
      {:reply, :ok, state}
    else
      state =
        state
        |> Map.put(:transcript, transcript)
        |> notify_messages_changed()

      {:reply, :ok, state}
    end
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

  def handle_call(
        {:branch_at, _turn_index},
        _from,
        %{continuation: %Continuation{active_request: %Request{}}} = state
      ),
      do: {:reply, {:error, :request_active}, state}

  def handle_call(
        {:branch_at, _turn_index},
        _from,
        %{continuation: %Continuation{tool_checkpoint: %{}}} = state
      ),
      do: {:reply, {:error, :effect_reconciliation_required}, state}

  def handle_call({:branch_at, turn_index}, _from, state) do
    case Transcript.branch_at(state.transcript, turn_index, DateTime.utc_now()) do
      {:ok, transcript, branch} ->
        reply_to_branch_at(state, turn_index, transcript, branch)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:list_branches, _from, state) do
    {:reply, {:ok, Branch.list(Transcript.branches(state.transcript))}, state}
  end

  def handle_call(
        {:switch_branch, _branch_index},
        _from,
        %{continuation: %Continuation{active_request: %Request{}}} = state
      ),
      do: {:reply, {:error, :request_active}, state}

  def handle_call(
        {:switch_branch, _branch_index},
        _from,
        %{continuation: %Continuation{tool_checkpoint: %{}}} = state
      ),
      do: {:reply, {:error, :effect_reconciliation_required}, state}

  def handle_call({:switch_branch, branch_index}, _from, state) do
    branch = Enum.at(Transcript.branches(state.transcript), branch_index - 1)

    case {branch, Transcript.switch_branch(state.transcript, branch_index)} do
      {%Branch{name: branch_name}, {:ok, transcript}} ->
        reply_to_switch_branch(state, transcript, branch_name)

      {_branch, {:error, reason}} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:begin_native_dispatch, request_id, source}, {worker, _}, state) do
    begin_native_dispatch(state, worker, request_id, source)
  end

  def handle_call(
        {:assess_native_dispatch, %Dispatch{} = attempt, digest, %RequestCapacity{} = assessment},
        _from,
        state
      ) do
    assess_native_dispatch(state, attempt, digest, assessment)
  end

  def handle_call({:checkpoint_tool_group, request_id, messages, calls}, _from, state)
      when is_binary(request_id) and is_list(messages) and is_list(calls) do
    with {:ok, checkpoint_id, continuation} <-
           Continuation.checkpoint_tool_group(state.continuation, request_id, messages, calls),
         {:ok, committed} <-
           commit_effect_snapshot(state, %{state | continuation: continuation}) do
      {:reply, {:ok, checkpoint_id}, committed}
    else
      {:error, reason} ->
        {:reply, {:error, {:tool_checkpoint_failed, reason}}, state}
    end
  end

  def handle_call({:prepare_tool_invocation, %Invocation{} = invocation}, {worker, _}, state) do
    prepare_tool_invocation(state, invocation, worker)
  end

  def handle_call({:start_tool_invocation, %Invocation{} = invocation}, {worker, _}, state) do
    start_tool_invocation(state, invocation, worker)
  end

  def handle_call({:checklist_invocation, %Invocation{} = invocation}, {worker, _}, state) do
    reply_to_checklist_invocation(state, invocation, worker)
  end

  def handle_call({:question_invocation, %Invocation{} = invocation}, from, state) do
    begin_question(state, invocation, from)
  end

  def handle_call({:tool_storage_failed, %Invocation{} = invocation, reason}, {worker, _}, state) do
    record_tool_storage_failure(state, invocation, worker, reason)
  end

  def handle_call(
        {:admit_tool_effect, request_id, checkpoint_id, tool_call_id, name, args},
        _from,
        state
      )
      when is_binary(request_id) and is_binary(checkpoint_id) and is_binary(tool_call_id) and
             is_binary(name) and is_map(args) do
    case Continuation.admit_tool_effect(
           state.continuation,
           request_id,
           checkpoint_id,
           tool_call_id,
           name,
           args
         ) do
      {:ok, continuation} ->
        admit_tool_effect_capture(
          state,
          %{state | continuation: continuation},
          checkpoint_id,
          tool_call_id,
          name,
          args
        )

      {:error, reason} ->
        {:reply, {:error, {:effect_admission_failed, reason}}, state}
    end
  end

  def handle_call(
        {:complete_tool_effect, request_id, checkpoint_id, tool_call_id, result_message, change},
        _from,
        state
      )
      when is_binary(request_id) and is_binary(checkpoint_id) and is_binary(tool_call_id) do
    identity = {request_id, checkpoint_id, tool_call_id}

    with :ok <- invocation_storage_outcome(state, identity),
         {:ok, changes} <- retain_file_change(state.file_changes, identity, change),
         {:ok, _outcome, _reason} <- ToolCall.saved_outcome(result_message.metadata),
         {:ok, continuation} <-
           Continuation.complete_tool_effect(
             state.continuation,
             request_id,
             checkpoint_id,
             tool_call_id,
             result_message
           ) do
      reply_completed_effect(state, continuation, changes, identity, result_message)
    else
      {:error, reason} ->
        {:reply, {:error, {:tool_outcome_persistence_failed, reason}}, state}
    end
  end

  @spec reply_completed_effect(
          state(),
          Continuation.t(),
          [FileChange.t()],
          FileChange.identity(),
          ReqLLM.Message.t()
        ) ::
          {:reply, :ok | {:error, term()}, state()}
  defp reply_completed_effect(
         %{continuation: continuation, file_changes: changes} = state,
         continuation,
         changes,
         _identity,
         _message
       ),
       do: {:reply, :ok, state}

  defp reply_completed_effect(
         state,
         continuation,
         changes,
         {request_id, _, tool_call_id} = identity,
         result_message
       ) do
    candidate =
      %{state | continuation: continuation, file_changes: changes}
      |> install_saved_tool_result(tool_call_id, result_message)

    case commit_effect_snapshot(state, candidate) do
      {:ok, committed} ->
        committed =
          retire_completed_approval(committed, request_id, tool_call_id, result_message, :saved)

        entries =
          Map.delete(
            committed.tool_authority.invocations,
            identity
          )

        authority = %{committed.tool_authority | invocations: entries}
        {:reply, :ok, %{committed | tool_authority: authority}}

      {:error, reason} ->
        failed =
          mark_tool_outcome_persistence_failed(
            state,
            identity,
            reason,
            result_message
          )
          |> retire_completed_approval(request_id, tool_call_id, result_message, :uncertain)

        {:reply, {:error, {:tool_outcome_persistence_failed, reason}}, failed}
    end
  end

  @spec retain_file_change([FileChange.t()], FileChange.identity(), FileChange.t() | nil) ::
          {:ok, [FileChange.t()]} | {:error, :file_change_identity_conflict}
  defp retain_file_change(changes, identity, change) do
    case {Enum.find(changes, &(&1.identity == identity)), change} do
      {same, same} -> {:ok, changes}
      {nil, %FileChange{identity: ^identity}} -> {:ok, [change | changes]}
      _ -> {:error, :file_change_identity_conflict}
    end
  end

  @spec invocation_storage_outcome(state(), tuple()) :: :ok | {:error, term()}
  defp invocation_storage_outcome(state, key) do
    case Map.get(state.tool_authority.invocations, key) do
      %{failure: nil} -> :ok
      %{failure: {:tool_outcome_persistence_failed, _reason}} -> :ok
      %{failure: reason} -> {:error, {:effect_admission_failed, reason}}
      _ordinary_result -> :ok
    end
  end

  @spec mark_tool_outcome_persistence_failed(state(), tuple(), term(), ReqLLM.Message.t()) ::
          state()
  defp mark_tool_outcome_persistence_failed(
         state,
         {_request, _checkpoint, id} = key,
         reason,
         result
       ) do
    state =
      case Map.fetch(state.tool_authority.invocations, key) do
        {:ok, entry} ->
          entries =
            Map.put(state.tool_authority.invocations, key, %{
              entry
              | failure: {:tool_outcome_persistence_failed, reason}
            })

          %{state | tool_authority: %{state.tool_authority | invocations: entries}}

        :error ->
          state
      end

    transcript =
      Transcript.update_tool_call(state.transcript, id, fn tool ->
        output = Map.get(result.metadata, :output) || tool.output
        explanation = uncertain_tool_result_text(tool.result, result_message_text(result))
        ToolCall.result_persistence_failed(tool, explanation, output)
      end)

    %{state | transcript: transcript}
  end

  defp uncertain_tool_result_text("", returned),
    do: "Tool result persistence is uncertain; no durable outcome is confirmed.\n\n" <> returned

  defp uncertain_tool_result_text(partial, returned),
    do:
      "Tool result persistence is uncertain; no durable outcome is confirmed.\n\n" <>
        partial <> "\n\nReturned result:\n" <> returned

  @spec install_saved_tool_result(state(), String.t(), ReqLLM.Message.t()) :: state()
  defp install_saved_tool_result(state, tool_call_id, result_message) do
    transcript =
      Transcript.update_tool_call(state.transcript, tool_call_id, fn tool ->
        {:tool_call, reconciled} =
          reconcile_transcript_tool_call(tool, %{
            status: :completed,
            result_message: result_message
          })

        reconciled
      end)

    %{state | transcript: transcript}
  end

  @spec retire_completed_approval(
          state(),
          String.t(),
          String.t(),
          ReqLLM.Message.t(),
          :saved | :uncertain
        ) :: state()
  defp retire_completed_approval(
         %{continuation: %Continuation{active_request: %Request{request_id: request_id}}} = state,
         request_id,
         tool_call_id,
         result_message,
         durability
       ) do
    case TurnExecution.resolve_approval(state.turn_execution, tool_call_id, :reject) do
      {:ok, approval, execution} ->
        resolution = approval_retirement_reason(result_message.metadata, durability)

        state =
          {state, approval, resolution}
          |> record_approval_resolution()
          |> broadcast_approval_retirement()
          |> notify_messages_changed()
          |> announce_display_status(execution)

        %{state | turn_execution: execution}

      {:error, _not_pending} ->
        state
    end
  end

  defp retire_completed_approval(state, _request_id, _tool_call_id, _message, _durability),
    do: state

  defp approval_retirement_reason(%{tool_outcome_reason: :approval_timeout}, _durability),
    do: :approval_timeout

  defp approval_retirement_reason(_metadata, :uncertain), do: :interrupted
  defp approval_retirement_reason(%{tool_outcome: :denied}, :saved), do: :reject
  defp approval_retirement_reason(_metadata, :saved), do: :interrupted

  @spec broadcast_approval_retirement(approval_retirement()) :: state()
  defp broadcast_approval_retirement({state, approval, resolution}) do
    Notifier.clear_approval()
    %PublicApproval{target: target} = public_pending_approval(approval, state)
    broadcast(state, {:approval_resolved, target, resolution})
  end

  @spec record_tool_storage_failure(state(), Invocation.t(), pid(), term()) ::
          {:reply, term(), state()}
  defp record_tool_storage_failure(state, invocation, worker, reason) do
    key = Invocation.key(invocation)

    case Map.get(state.tool_authority.invocations, key) do
      %{invocation: ^invocation, worker: ^worker, started: true} = entry ->
        entries = Map.put(state.tool_authority.invocations, key, %{entry | failure: reason})
        {:reply, :ok, %{state | tool_authority: %{state.tool_authority | invocations: entries}}}

      _not_started ->
        {:reply, {:error, :invocation_not_started}, state}
    end
  end

  @spec admit_tool_effect_capture(
          state(),
          state(),
          String.t(),
          String.t(),
          String.t(),
          map()
        ) :: {:reply, term(), state()}
  defp admit_tool_effect_capture(state, candidate, checkpoint_id, tool_call_id, name, args) do
    case commit_effect_snapshot(state, candidate) do
      {:ok, committed} ->
        case ensure_artifact_store(committed) do
          {:ok, store} ->
            record_tool_effect_admission(
              committed,
              store,
              checkpoint_id,
              tool_call_id,
              name,
              args
            )

          {:error, reason} ->
            {:reply, {:error, {:artifact_store_admission_failed, reason}}, committed}
        end

      {:error, reason} ->
        {:reply, {:error, {:effect_admission_failed, reason}}, state}
    end
  end

  @spec record_tool_effect_admission(
          state(),
          GenServer.server(),
          String.t(),
          String.t(),
          String.t(),
          map()
        ) :: {:reply, term(), state()}
  defp record_tool_effect_admission(state, store, checkpoint_id, tool_call_id, name, args) do
    result =
      case EventLog.record(
             state.session_id,
             :tool_call_started,
             %{
               checkpoint_id: checkpoint_id,
               tool_call_id: tool_call_id,
               name: name,
               args: args
             },
             state.event_log_server
           ) do
        {:queued, receipt} -> EventLog.await(receipt)
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:persisted, _event_id} ->
        {:reply, {:ok, store}, state}

      {:error, reason} ->
        message =
          "Tool effect admission was durably saved, but its event journal record failed: #{inspect(reason)}"

        warned =
          state
          |> append_error_message_once(message)
          |> notify_messages_changed()
          |> broadcast({:warning, message})

        {:reply, {:ok, store}, warned}
    end
  end

  @authorization_options [:agent_tool_permissions, :agent_tool_approval, :agent_destructive_tools]

  @spec prepare_tool_invocation(state(), Invocation.t(), pid()) :: {:reply, term(), state()}
  defp prepare_tool_invocation(state, invocation, worker) do
    key = Invocation.key(invocation)

    with {:ok, declaration} <- invocation_declaration(state, invocation),
         false <- Map.has_key?(state.tool_authority.invocations, key),
         {:ok, values, stamp} <-
           Options.read_versioned(state.tool_authority.options, @authorization_options),
         {:ok, spec, registration, current} <-
           resolve_invocation(state, declaration, invocation.name),
         true <- current == declaration,
         {:ok, requirement} <- authorize_invocation(state, spec, invocation.arguments, values),
         :ok <- Options.validate_version(state.tool_authority.options, stamp) do
      entry = %{
        invocation: invocation,
        worker: worker,
        registration: registration,
        stamp: stamp,
        requirement: requirement,
        approved: false,
        started: false,
        revision: state.tool_authority.revision,
        failure: nil
      }

      entries = Map.put(state.tool_authority.invocations, key, entry)
      authority = %{state.tool_authority | invocations: entries}
      {:reply, {:ok, requirement}, %{state | tool_authority: authority}}
    else
      true -> {:reply, {:refused, :duplicate_invocation}, state}
      false -> {:reply, {:refused, :tool_declaration_changed}, state}
      {:error, reason} -> {:reply, {:refused, reason}, state}
    end
  end

  @spec start_tool_invocation(state(), Invocation.t(), pid()) :: {:reply, term(), state()}
  defp start_tool_invocation(state, invocation, worker) do
    key = Invocation.key(invocation)

    with {:ok, declaration} <- invocation_declaration(state, invocation),
         {:ok, entry} <- fetch_prepared_invocation(state, invocation, worker),
         {:ok, _spec, registration, current} <-
           resolve_invocation(state, declaration, invocation.name),
         true <- current == declaration and registration == entry.registration,
         {:ok, continuation} <-
           Continuation.admit_tool_effect(
             state.continuation,
             invocation.request_id,
             invocation.checkpoint_id,
             invocation.call_id,
             invocation.name,
             invocation.arguments
           ) do
      case admit_tool_effect_capture(
             state,
             %{state | continuation: continuation},
             invocation.checkpoint_id,
             invocation.call_id,
             invocation.name,
             invocation.arguments
           ) do
        {:reply, {:ok, store}, committed} ->
          final_start_invocation(committed, invocation, key, entry, declaration, store)

        {:reply, {:error, reason}, committed} ->
          entries = Map.put(committed.tool_authority.invocations, key, %{entry | failure: reason})
          authority = %{committed.tool_authority | invocations: entries}
          {:reply, {:error, reason}, %{committed | tool_authority: authority}}
      end
    else
      false -> {:reply, {:refused, :tool_declaration_changed}, state}
      {:error, reason} -> {:reply, {:refused, reason}, state}
    end
  end

  @spec final_start_invocation(state(), Invocation.t(), tuple(), map(), map(), GenServer.server()) ::
          {:reply, term(), state()}
  defp final_start_invocation(state, invocation, key, entry, declaration, store) do
    policy_revision = state.tool_authority.revision

    with {:ok, values, stamp} <-
           Options.read_versioned(state.tool_authority.options, @authorization_options),
         true <- entry.revision == policy_revision,
         {:ok, provisional, registration, current} <-
           resolve_invocation(state, declaration, invocation.name),
         true <- registration == entry.registration and current == declaration,
         {:ok, requirement} <-
           authorize_invocation(state, provisional, invocation.arguments, values),
         :ok <- validate_invocation_approval(entry, requirement, stamp),
         {:ok, selected, ^registration, ^declaration} <-
           resolve_invocation(state, declaration, invocation.name),
         :ok <- Options.validate_version(state.tool_authority.options, stamp) do
      entries = Map.put(state.tool_authority.invocations, key, %{entry | started: true})
      authority = %{state.tool_authority | invocations: entries}
      # The session id names the task this invocation's edits belong to.
      {:reply, {:ok, selected, store, state.session_id}, %{state | tool_authority: authority}}
    else
      false ->
        {:reply, {:refused, :tool_declaration_changed}, state}

      {:ok, _spec, _registration, _declaration} ->
        {:reply, {:refused, :tool_declaration_changed}, state}

      {:error, reason} ->
        {:reply, {:refused, reason}, state}
    end
  end

  @spec invocation_declaration(state(), Invocation.t(), :pending | :admitted) ::
          {:ok, map()} | {:error, term()}
  defp invocation_declaration(state, invocation, phase \\ :pending)

  defp invocation_declaration(
         %{
           continuation: %Continuation{
             active_request: %Request{} = request,
             tool_checkpoint: %{} = checkpoint
           }
         },
         invocation,
         phase
       ) do
    with true <-
           request.request_id == invocation.request_id and
             checkpoint.request_id == invocation.request_id and
             checkpoint.checkpoint_id == invocation.checkpoint_id and
             checkpoint.epoch_id == request.epoch_id,
         %{name: name, arguments: arguments, status: status} <-
           Enum.find(checkpoint.calls, &(&1.tool_call_id == invocation.call_id)),
         true <-
           name == invocation.name and arguments == invocation.arguments and status == phase,
         %MingaAgent.Session.Prefix{schemas: schemas} <- request.prefix,
         %{} = declaration <- Enum.find(schemas, &(&1.name == name)) do
      {:ok, declaration}
    else
      _mismatch -> {:error, :tool_call_identity_mismatch}
    end
  end

  defp invocation_declaration(_state, _invocation, _phase), do: {:error, :stale_request}

  @spec reply_to_checklist_invocation(state(), Invocation.t(), pid()) :: {:reply, term(), state()}
  defp reply_to_checklist_invocation(state, invocation, worker) do
    key = Invocation.key(invocation)

    with %{invocation: ^invocation, worker: ^worker, started: true, failure: nil} <-
           Map.get(state.tool_authority.invocations, key),
         {:ok, _declaration} <- invocation_declaration(state, invocation, :admitted) do
      apply_checklist_invocation(state, invocation)
    else
      _stale -> {:reply, {:error, :stale_invocation}, state}
    end
  end

  @spec begin_question(state(), Invocation.t(), GenServer.from()) ::
          {:noreply, state()} | {:reply, {:error, term()}, state()}
  defp begin_question(state, %Invocation{name: "ask_user"} = invocation, {worker, _} = from) do
    key = Invocation.key(invocation)

    with %{invocation: ^invocation, worker: ^worker, started: true, failure: nil} <-
           Map.get(state.tool_authority.invocations, key),
         {:ok, _declaration} <- invocation_declaration(state, invocation, :admitted),
         true <-
           SubscriberLifecycle.driver_supports_questions?(state.subscriber_lifecycle) or
             {:error, :no_question_driver},
         {:ok, question} <-
           Question.new(
             invocation.arguments["prompt"],
             Map.get(invocation.arguments, "choices", [])
           ) do
      target = %QuestionTarget{
        session_id: state.session_id,
        request_id: invocation.request_id,
        checkpoint_id: invocation.checkpoint_id,
        tool_call_id: invocation.call_id
      }

      install_pending_question(state, %PendingQuestion{
        question: question,
        target: target,
        reply_to: from,
        monitor: Process.monitor(worker)
      })
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _stale -> {:reply, {:error, :stale_invocation}, state}
    end
  end

  defp begin_question(state, _invocation, _from), do: {:reply, {:error, :stale_invocation}, state}

  @spec install_pending_question(state(), PendingQuestion.t()) ::
          {:noreply, state()} | {:reply, {:error, term()}, state()}
  defp install_pending_question(state, pending) do
    case TurnExecution.request_question(state.turn_execution, pending) do
      {:ok, execution} ->
        state =
          %{state | turn_execution: execution}
          |> broadcast({:question_requested, pending.target, pending.question})

        {:noreply, state}

      {:error, reason} ->
        Process.demonitor(pending.monitor, [:flush])
        {:reply, {:error, reason}, state}
    end
  end

  @spec public_question(TurnExecution.t()) :: {QuestionTarget.t(), Question.t()} | nil
  defp public_question(execution) do
    case TurnExecution.pending_question(execution) do
      %PendingQuestion{target: target, question: question} -> {target, question}
      nil -> nil
    end
  end

  @spec respond_to_question(state(), QuestionTarget.t(), Question.response()) ::
          {:reply, :ok | {:error, :question_not_found | :invalid_answer}, state()}
  defp respond_to_question(state, target, response) do
    case TurnExecution.resolve_question(state.turn_execution, target, response) do
      {:ok, pending, outcome, execution} ->
        deliver_question_answer(state, pending, outcome, execution)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @spec deliver_question_answer(
          state(),
          PendingQuestion.t(),
          Question.outcome(),
          TurnExecution.t()
        ) ::
          {:reply, :ok | {:error, :question_not_found}, state()}
  defp deliver_question_answer(state, pending, outcome, execution) do
    {worker, _} = pending.reply_to

    if Process.alive?(worker) do
      Process.demonitor(pending.monitor, [:flush])
      GenServer.reply(pending.reply_to, {:ok, outcome})

      state =
        broadcast(
          %{state | turn_execution: execution},
          {question_resolution(outcome), pending.target}
        )

      {:reply, :ok, state}
    else
      {:reply, {:error, :question_not_found}, interrupt_question(state)}
    end
  end

  @spec question_resolution(Question.outcome()) :: :question_answered | :question_cancelled
  defp question_resolution({:answered, _answer}), do: :question_answered
  defp question_resolution(:cancelled), do: :question_cancelled

  @spec interrupt_question(state()) :: state()
  defp interrupt_question(state) do
    case TurnExecution.interrupt_question(state.turn_execution) do
      {:interrupted, pending, execution} ->
        Process.demonitor(pending.monitor, [:flush])
        GenServer.reply(pending.reply_to, {:error, :question_interrupted})

        %{state | turn_execution: execution}
        |> broadcast({:question_interrupted, pending.target})

      :no_question ->
        state
    end
  end

  @spec handle_question_worker_down(state(), pid(), reference(), term()) :: state()
  defp handle_question_worker_down(state, worker, ref, reason) do
    case TurnExecution.pending_question(state.turn_execution) do
      %PendingQuestion{reply_to: {^worker, _}, monitor: ^ref} -> interrupt_question(state)
      _other -> connection_dependency_down(state, worker, ref, reason)
    end
  end

  @spec apply_checklist_invocation(state(), Invocation.t()) :: {:reply, term(), state()}
  defp apply_checklist_invocation(state, %Invocation{name: "todo_read", arguments: arguments})
       when map_size(arguments) == 0 do
    {:reply, {:page, state.checklist, Persistence.enabled?(state.persistence), 0}, state}
  end

  defp apply_checklist_invocation(
         state,
         %Invocation{
           name: "todo_read",
           arguments: %{"offset" => offset, "expected_revision" => expected}
         }
       )
       when is_integer(offset) and offset in 1..100 and is_integer(expected) and expected >= 0 do
    {revision, tasks} = Checklist.snapshot(state.checklist)

    case {revision == expected, offset < length(tasks)} do
      {true, true} ->
        {:reply, {:page, state.checklist, Persistence.enabled?(state.persistence), offset}, state}

      {false, _} ->
        {:reply, {:error, {:stale_revision, revision}}, state}

      {true, false} ->
        {:reply, {:error, :invalid_checklist_offset}, state}
    end
  end

  defp apply_checklist_invocation(
         state,
         %Invocation{
           name: "todo_write",
           arguments: %{"expected_revision" => expected, "tasks" => items}
         }
       )
       when is_integer(expected) and expected >= 0 and is_list(items) do
    {revision, _tasks} = Checklist.snapshot(state.checklist)

    with true <- revision == expected or {:error, {:stale_revision, revision}},
         {:ok, resolved} <- resolve_checklist_references(state, items),
         {:ok, checklist} <- Checklist.replace(state.checklist, expected, resolved),
         {:ok, committed} <-
           persist_session_transition(%{state | checklist: checklist}) do
      response =
        {:written, expected + 1, length(items), Persistence.enabled?(committed.persistence)}

      {:reply, response, publish_checklist(committed)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp apply_checklist_invocation(state, _invocation),
    do: {:reply, {:error, :invalid_checklist_invocation}, state}

  @spec publish_checklist(state()) :: state()
  defp publish_checklist(state) do
    {_revision, todos} = Checklist.snapshot(state.checklist)
    broadcast(state, {:todo_plan_updated, todos})
  end

  @spec resolve_checklist_references(state(), [term()]) :: {:ok, [map()]} | {:error, term()}
  defp resolve_checklist_references(state, items),
    do: resolve_checklist_references(state, items, 100, [])

  @spec resolve_checklist_references(state(), [term()], non_neg_integer(), [map()]) ::
          {:ok, [map()]} | {:error, term()}
  defp resolve_checklist_references(_state, [], _remaining, resolved),
    do: {:ok, Enum.reverse(resolved)}

  defp resolve_checklist_references(state, [item | rest], remaining, resolved)
       when remaining > 0 do
    with {:ok, item} <- resolve_checklist_reference(state, item),
         do: resolve_checklist_references(state, rest, remaining - 1, [item | resolved])
  end

  defp resolve_checklist_references(_state, _items, 0, _resolved),
    do: {:error, :invalid_checklist}

  @spec resolve_checklist_reference(state(), term()) :: {:ok, map()} | {:error, term()}
  defp resolve_checklist_reference(state, %{"result_ref" => token} = item)
       when is_binary(token) and byte_size(token) <= 140 do
    with {:ok, store} <- ensure_artifact_store(state),
         {:ok, reference} <- ArtifactStore.reference(store, token) do
      {:ok, %{item | "result_ref" => reference}}
    end
  end

  defp resolve_checklist_reference(_state, %{"result_ref" => nil} = item), do: {:ok, item}

  defp resolve_checklist_reference(_state, %{"result_ref" => _invalid}),
    do: {:error, :invalid_checklist}

  defp resolve_checklist_reference(_state, item) when is_map(item), do: {:ok, item}
  defp resolve_checklist_reference(_state, _item), do: {:error, :invalid_checklist}

  @spec fetch_prepared_invocation(state(), Invocation.t(), pid()) ::
          {:ok, map()} | {:error, term()}
  defp fetch_prepared_invocation(state, invocation, worker) do
    case Map.get(state.tool_authority.invocations, Invocation.key(invocation)) do
      %{invocation: ^invocation, worker: ^worker, started: false, failure: nil} = entry ->
        {:ok, entry}

      _missing_or_started ->
        {:error, :invocation_not_eligible}
    end
  end

  @spec resolve_invocation(state(), map(), String.t()) ::
          {:ok, ToolSpec.t(), term(), map()} | {:error, term()}
  defp resolve_invocation(state, %{source: {:local, name}}, name) do
    GenServer.call(ProviderLifecycle.pid(state.provider), {:resolve_local_tool, name})
  end

  defp resolve_invocation(state, _declaration, name) do
    with {:ok, spec, registration} <-
           ToolRegistry.resolve_execution(state.tool_authority.registry, name) do
      tool = ReqLLMAdapter.tool(spec, :registry)
      {:ok, spec, registration, ReqLLMAdapter.declaration(tool)}
    end
  end

  @spec authorize_invocation(state(), ToolSpec.t(), map(), map()) ::
          {:ok, :ready | :approval_required} | {:error, term()}
  defp authorize_invocation(state, spec, args, %{
         agent_tool_permissions: permissions,
         agent_tool_approval: approval,
         agent_destructive_tools: destructive
       })
       when (is_map(permissions) or is_nil(permissions)) and
              approval in [:none, :all, :destructive] and is_list(destructive) do
    case {state.tool_authority.read_only?, TurnExecution.mode(state.turn_execution)} do
      {true, _mode} ->
        if MingaAgent.Tools.read_only_name?(spec.name),
          do: tool_policy(spec, args, permissions, approval, destructive),
          else: {:error, :read_only_session}

      {false, :plan} ->
        if MingaAgent.Tool.PlanMode.blocked?(spec.name, args),
          do: {:error, :plan_mode},
          else: tool_policy(spec, args, permissions, approval, destructive)

      {false, :exec} ->
        tool_policy(spec, args, permissions, approval, destructive)
    end
  end

  defp authorize_invocation(_state, _spec, _args, _invalid), do: {:error, :options_unavailable}

  @spec tool_policy(ToolSpec.t(), map(), map() | nil, atom(), list()) ::
          {:ok, :ready | :approval_required} | {:error, term()}
  defp tool_policy(spec, args, permissions, approval, destructive) do
    case Map.get(permissions || %{}, spec.name) do
      permission when permission in [:deny, "deny"] -> {:error, :permission_denied}
      permission when permission in [:allow, "allow"] -> {:ok, :ready}
      permission when permission in [:ask, "ask"] -> {:ok, :approval_required}
      nil -> default_tool_policy(spec, args, approval, destructive)
      _invalid -> {:error, :invalid_tool_permission}
    end
  end

  @spec default_tool_policy(ToolSpec.t(), map(), atom(), list()) ::
          {:ok, :ready | :approval_required} | {:error, term()}
  defp default_tool_policy(spec, args, approval, destructive) do
    case registry_approval(spec) do
      :deny ->
        {:error, :tool_denied}

      level ->
        default_policy_requirement(
          approval,
          level == :ask or MingaAgent.Tools.destructive?(spec.name, args, destructive)
        )
    end
  end

  @spec registry_approval(ToolSpec.t()) :: ToolSpec.approval_level() | nil
  defp registry_approval(%ToolSpec{source: :builtin}), do: nil
  defp registry_approval(%ToolSpec{source: {:bundle, _}}), do: nil
  defp registry_approval(%ToolSpec{approval_level: level}), do: level

  @spec default_policy_requirement(atom(), boolean()) :: {:ok, :ready | :approval_required}
  defp default_policy_requirement(:none, _destructive?), do: {:ok, :ready}
  defp default_policy_requirement(:all, _destructive?), do: {:ok, :approval_required}
  defp default_policy_requirement(:destructive, true), do: {:ok, :approval_required}
  defp default_policy_requirement(:destructive, false), do: {:ok, :ready}

  @spec validate_invocation_approval(map(), atom(), Options.version_stamp()) ::
          :ok | {:error, term()}
  defp validate_invocation_approval(
         %{requirement: :approval_required, approved: true, stamp: stamp},
         _requirement,
         stamp
       ),
       do: :ok

  defp validate_invocation_approval(%{requirement: :ready}, :ready, _stamp), do: :ok
  defp validate_invocation_approval(_entry, _requirement, _stamp), do: {:error, :approval_changed}

  @spec approve_prepared_invocation(approval_resolution()) :: approval_resolution()
  defp approve_prepared_invocation({state, approval, decision}) do
    entries =
      Map.new(state.tool_authority.invocations, fn {key, entry} ->
        case entry do
          %{
            worker: worker,
            invocation: %{call_id: call_id, name: name, arguments: args},
            started: false
          }
          when worker == approval.reply_to and call_id == approval.tool_call_id and
                 name == approval.name and args == approval.args ->
            {key, %{entry | approved: decision != :reject}}

          _other ->
            {key, entry}
        end
      end)

    {%{state | tool_authority: %{state.tool_authority | invocations: entries}}, approval,
     decision}
  end

  @spec begin_approved_tool_execution(approval_resolution()) :: approval_resolution()
  defp begin_approved_tool_execution({_state, _approval, :reject} = resolution), do: resolution

  defp begin_approved_tool_execution({state, approval, decision})
       when decision in [:approve, :approve_session, :approve_turn] do
    transcript =
      Transcript.update_tool_call(
        state.transcript,
        approval.tool_call_id,
        &ToolCall.approve_execution/1
      )

    {%{state | transcript: transcript}, approval, decision}
  end

  @spec revise_tool_policy(state(), TurnExecution.t()) :: state()
  defp revise_tool_policy(state, execution) do
    %{
      state
      | turn_execution: execution,
        tool_authority: %{state.tool_authority | revision: make_ref()}
    }
  end

  @spec ensure_artifact_store(state()) :: {:ok, GenServer.server()} | {:error, term()}
  defp ensure_artifact_store(%{artifact_runtime: nil, session_id: session_id}),
    do: ArtifactStores.ensure_record(session_id)

  defp ensure_artifact_store(%{
         artifact_runtime: %ArtifactRuntime{} = runtime,
         session_id: session_id
       }),
       do: ArtifactStores.ensure_record(session_id, runtime)

  @spec reply_to_seed_messages(state(), [Message.t()], [ReqLLM.Message.t()]) ::
          {:reply, term(), state()}
  defp reply_to_seed_messages(state, _messages, []), do: {:reply, :ok, state}

  defp reply_to_seed_messages(state, messages, model_messages) do
    candidate = append_msgs(state, messages)

    [{transcript_id, _message} | _rest] =
      candidate.transcript |> Transcript.messages_with_ids() |> Enum.reverse()

    case Continuation.seed_messages(state.continuation, model_messages, transcript_id) do
      {:ok, continuation} -> commit_seed_messages(state, candidate, continuation)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @spec commit_seed_messages(state(), state(), Continuation.t()) :: {:reply, term(), state()}
  defp commit_seed_messages(state, candidate, continuation) do
    case commit_conversation_transition(state, %{candidate | continuation: continuation}) do
      {:ok, committed} ->
        {:reply, :ok, committed}

      {:error, reason, failed} ->
        {:reply, {:error, {:conversation_persistence_failed, reason}}, failed}
    end
  end

  @spec persist_legacy_import(
          state(),
          String.t(),
          SessionStore.session_data(),
          GenServer.from()
        ) ::
          {:reply, term(), state()} | {:noreply, state()}
  defp persist_legacy_import(state, session_id, legacy_data, from) do
    imported_data = prepare_legacy_import(legacy_data, legacy_import_id(session_id))

    case SessionStore.save(imported_data, state.session_store_dir, artifact_store_opts(state)) do
      :ok ->
        begin_loaded_session_restore(state, imported_data, from)

      {:error, reason} ->
        {:reply, {:error, {:legacy_import_persistence_failed, reason}}, state}
    end
  end

  @spec reply_to_compact(state(), term()) :: {:reply, term(), state()}
  defp reply_to_compact(state, {:ok, messages, summary}) do
    case Continuation.replace_messages(state.continuation, messages) do
      {:ok, continuation} -> persist_compacted_messages(state, continuation, summary)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp reply_to_compact(state, {:error, _reason} = error), do: {:reply, error, state}

  @spec persist_compacted_messages(state(), Continuation.t(), String.t()) ::
          {:reply, term(), state()}
  defp persist_compacted_messages(state, continuation, summary) do
    candidate = %{state | continuation: continuation}
    {persisted, save_result} = persist_completed_boundary(candidate)

    case save_result do
      :ok ->
        {:reply, {:ok, summary}, persisted}

      {:error, reason} ->
        {:reply, {:error, {:persistence_failed, reason}},
         %{persisted | continuation: state.continuation}}
    end
  end

  @spec reply_to_branch_at(state(), pos_integer(), Transcript.t(), Branch.t()) ::
          {:reply, term(), state()}
  defp reply_to_branch_at(state, turn_index, transcript, branch) do
    [{selected_id, _message} | _rest] =
      transcript |> Transcript.messages_with_ids() |> Enum.reverse()

    case Continuation.branch_at(state.continuation, branch.name, selected_id) do
      {:ok, continuation} ->
        {checklist, archive} =
          ChecklistArchive.fork(
            state.checklist_archive,
            branch.name,
            selected_id,
            state.checklist
          )

        candidate = %{
          state
          | transcript: transcript,
            continuation: continuation,
            checklist: checklist,
            checklist_archive: archive
        }

        commit_branch_at(state, candidate, turn_index, branch.name)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @spec commit_branch_at(state(), state(), pos_integer(), String.t()) ::
          {:reply, term(), state()}
  defp commit_branch_at(state, candidate, turn_index, branch_name) do
    with :ok <- validate_branch_model(candidate),
         {:ok, committed} <- commit_conversation_transition(state, candidate) do
      {:reply, {:ok, "Branched at turn #{turn_index}. Branch saved as '#{branch_name}'."},
       publish_checklist(committed)}
    else
      {:error, reason, failed} ->
        {:reply, {:error, {:conversation_persistence_failed, reason}}, failed}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @spec reply_to_switch_branch(state(), Transcript.t(), String.t()) ::
          {:reply, term(), state()}
  defp reply_to_switch_branch(state, transcript, branch_name) do
    {checklist, archive} = ChecklistArchive.switch(state.checklist_archive, branch_name)

    candidate = %{
      state
      | transcript: transcript,
        checklist: checklist,
        checklist_archive: archive
    }

    case Continuation.switch_branch(state.continuation, branch_name) do
      {:ok, continuation} ->
        commit_branch_switch(state, %{candidate | continuation: continuation})

      {:error, :branch_not_resumable}
      when state.continuation.provenance == :legacy_reconstructed ->
        continuation = Continuation.import_legacy(Transcript.messages(transcript))

        candidate =
          %{candidate | continuation: continuation}
          |> append_system_message(
            "This explicitly imported legacy branch is portable reconstructed text. It is not a lossless continuation and no tool, attachment, or provider metadata was invented.",
            :info
          )

        commit_branch_switch(state, candidate)

      {:error, :branch_not_resumable} ->
        {:reply, {:error, :branch_not_resumable}, state}
    end
  end

  @spec commit_branch_switch(state(), state()) :: {:reply, term(), state()}
  defp commit_branch_switch(state, candidate) do
    with :ok <- validate_branch_model(candidate),
         {:ok, committed} <- commit_conversation_transition(state, candidate) do
      {:reply, :ok, publish_checklist(committed)}
    else
      {:error, reason, failed} ->
        {:reply, {:error, {:conversation_persistence_failed, reason}}, failed}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @spec validate_branch_model(state()) :: :ok | {:error, String.t()}
  defp validate_branch_model(%{model_selection: %ModelSelection{} = selection} = state) do
    case PrefixStore.resolve(state.continuation.prefixes, state.continuation.prefixes.selected) do
      %Prefix{identity: %{selection_id: branch_model}} ->
        if branch_model == ModelSelection.id(selection),
          do: :ok,
          else:
            {:error,
             "This branch uses another model. Select it with /model #{branch_model}, then switch branches."}

      _legacy ->
        :ok
    end
  end

  defp validate_branch_model(_state), do: :ok

  @spec reset_new_session(state(), String.t()) :: state()
  defp reset_new_session(state, session_id) do
    state = interrupt_question(state)
    source_execution = state.turn_execution
    state = interrupt_execution_approval(state, source_execution)

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
    execution = TurnExecution.reset(source_execution)

    state = %{
      state
      | session_id: session_id,
        custom_title: nil,
        archived?: false,
        created_at: now
    }

    state = invalidate_connection(state, :conversation)

    transcript =
      state.transcript
      |> Transcript.reset([Message.system("Session cleared · #{timestamp}")])
      |> Transcript.touch(now)

    state = %{
      state
      | transcript: transcript,
        continuation: Continuation.reset(state.continuation),
        checklist: Checklist.new(),
        checklist_archive: ChecklistArchive.new(),
        file_changes: [],
        tool_authority: %{state.tool_authority | revision: make_ref(), invocations: %{}}
    }

    state = install_job_ledger(state, JobLedger.new())

    record_critical_event(state, :session_started, %{
      model: state.provider.model_name,
      provider: state.provider.provider_name,
      background_subagent: state.background_subagent
    })

    state = announce_turn_status(state, execution)

    state = Map.put(state, :turn_execution, execution)

    state
    |> publish_checklist()
    |> notify_messages_changed()
  end

  @impl GenServer
  @spec handle_cast(term(), state()) :: {:noreply, state()}
  def handle_cast({:report_oauth_failure, target, ref, reason, caller}, state) do
    {:noreply, fail_oauth_workflow(state, target, ref, reason, caller)}
  end

  def handle_cast({:request_connection_cancel, target, operation_ref, caller}, state) do
    {:reply, _result, state} = cancel_connection_workflow(state, target, operation_ref, caller)
    {:noreply, state}
  end

  def handle_cast({:recall_volatile_queue, caller, conversation, workspace}, state) do
    if state.connection.conversation == conversation and
         not Persistence.enabled?(state.persistence) do
      {{steering, follow_up}, execution} = TurnExecution.recall_queues(state.turn_execution)

      send(
        caller,
        {:volatile_queue_recalled, self(), conversation, workspace, steering ++ follow_up}
      )

      {:noreply, broadcast(%{state | turn_execution: execution}, :queues_recalled)}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:request_connection_worker, target, ref, worker, caller}, state) do
    {:reply, result, state} =
      register_connection_worker_workflow(state, target, ref, worker, caller)

    send(worker, {:connection_worker_binding, ref, result})
    {:noreply, state}
  end

  def handle_cast(
        {:composer_draft, caller, record_id, correlation,
         {:queue, {record_id, _, _} = target, kind, draft, content}},
        state
      )
      when is_pid(caller) and node(caller) == node() do
    {:reply, result, next} = handle_queued_draft(state, target, kind, draft, content)
    send(caller, {:composer_draft_result, self(), record_id, correlation, result})
    {:noreply, next}
  end

  def handle_cast({:composer_draft, caller, record_id, correlation, {:queue, _, _, _, _}}, state)
      when is_pid(caller) and node(caller) == node() do
    send(
      caller,
      {:composer_draft_result, self(), record_id, correlation, {:error, :stale_target}}
    )

    {:noreply, state}
  end

  def handle_cast(
        {:composer_draft, _caller, _record_id, _correlation, {:queue, _, _, _, _}},
        state
      ),
      do: {:noreply, state}

  def handle_cast(
        {:composer_draft, caller, record_id, correlation, {:recall, revision, draft, action}},
        state
      )
      when is_pid(caller) and node(caller) == node() and is_binary(record_id) and
             is_integer(revision) and revision >= 0 and
             (is_struct(draft, DraftSnapshot) or is_nil(draft)) do
    {result, next} = recall_composer_draft(state, record_id, revision, draft, action)
    send(caller, {:composer_draft_result, self(), record_id, correlation, result})
    {:noreply, next}
  end

  def handle_cast({:composer_draft, caller, record_id, correlation, {:recall, _, _, _}}, state)
      when is_pid(caller) and node(caller) == node() do
    send(
      caller,
      {:composer_draft_result, self(), record_id, correlation, {:error, :invalid_draft_snapshot}}
    )

    {:noreply, state}
  end

  def handle_cast(
        {:composer_draft, _caller, _record_id, _correlation, {:recall, _, _, _}},
        state
      ),
      do: {:noreply, state}

  def handle_cast({:composer_draft, caller, record_id, correlation, operation}, state)
      when is_pid(caller) and node(caller) == node() do
    result =
      with :ok <- validate_composer_record(state, record_id) do
        composer_draft(state, record_id, operation)
      end

    send(caller, {:composer_draft_result, self(), record_id, correlation, result})
    {:noreply, state}
  end

  def handle_cast({:composer_draft, _caller, _record_id, _correlation, _operation}, state),
    do: {:noreply, state}

  def handle_cast({:confirm_queue_receipt, caller, record_id, {_, _, _, _} = receipt}, state)
      when is_pid(caller) and node(caller) == node() do
    {:reply, result, next} = acknowledge_queue_receipt(state, record_id, receipt)

    case result do
      {:error, reason} ->
        Minga.Log.warning(
          :agent,
          "Queue acknowledgement could not be recorded: #{inspect(reason)}"
        )

      :ok ->
        :ok
    end

    {:noreply, next}
  end

  def handle_cast({:confirm_queue_receipt, _caller, _record_id, _receipt}, state),
    do: {:noreply, state}

  def handle_cast({:add_system_message, text, level}, state) do
    state = append_system_message(state, text, level)
    state = notify_messages_changed(state)
    {:noreply, state}
  end

  def handle_cast({:add_system_message_for_id, expected_session_id, text, level}, state)
      when state.session_id == expected_session_id do
    state = append_system_message(state, text, level)
    state = notify_messages_changed(state)
    {:noreply, state}
  end

  def handle_cast({:add_system_message_for_id, _expected_session_id, _text, _level}, state) do
    {:noreply, state}
  end

  def handle_cast(:refresh_credentials, state) do
    {:noreply, state |> invalidate_model_discovery() |> refresh_credentials_state()}
  end

  @impl GenServer
  @spec handle_info(term(), state()) :: {:noreply, state()} | {:stop, term(), state()}
  def handle_info(:start_provider, state) do
    {state, _result} = maybe_start_provider_result(state)
    {:noreply, state}
  end

  def handle_info({:start_provider, token}, state) do
    case ProviderLifecycle.retry_due(state.provider, token) do
      {:start, lifecycle} ->
        state = %{state | provider: lifecycle}
        {state, _result} = refresh_credentials_state_result(state)
        {:noreply, state}

      {:stale, _lifecycle} ->
        {:noreply, state}
    end
  end

  def handle_info({:agent_provider_event, request_id, event}, state)
      when is_binary(request_id) do
    if Continuation.accepts?(state.continuation, request_id) do
      {:noreply, handle_provider_event(event, state)}
    else
      {:noreply, reject_stale_tool_approval(event, state)}
    end
  end

  def handle_info({:agent_provider_lifecycle_event, %Event.Error{} = event}, state) do
    state = retain_connection_error(state, event)
    {:noreply, report_turn_error(state, humanize_error(event, state))}
  end

  def handle_info({:agent_provider_event, %Event.SystemMessage{} = event}, state) do
    {:noreply, handle_provider_event(event, state)}
  end

  def handle_info({:agent_provider_event, _event_without_request_identity}, state) do
    Minga.Log.warning(
      :agent,
      "[Agent.Session] ignored provider response without request identity"
    )

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
        {:DOWN, monitor_ref, :process, pid, reason},
        %{
          provider: %ProviderLifecycle{
            phase: {:running, pid, monitor_ref, _lease, _retry}
          }
        } = state
      ) do
    {:noreply, handle_provider_death(state, reason)}
  end

  def handle_info(
        {:EXIT, pid, reason},
        %{
          provider: %ProviderLifecycle{
            phase: {:running, pid, monitor_ref, _lease, _retry}
          }
        } = state
      ) do
    Process.demonitor(monitor_ref, [:flush])
    {:noreply, handle_provider_death(state, reason)}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info({:job_started, job_id, _epoch}, state) do
    case JobLedger.fetch(state.job_ledger, job_id) do
      # A foreground job ends with its caller, so its caller stays monitored until the job settles.
      {:ok, %JobRecord{status: :running, background?: false}} -> {:noreply, state}
      _background_or_ended -> {:noreply, release_job_admission(state, job_id)}
    end
  end

  def handle_info({:job_settled, job_id, epoch, outcome, exit_code, output}, state) do
    ledger =
      JobLedger.settle(
        state.job_ledger,
        job_id,
        epoch,
        outcome,
        exit_code,
        output,
        DateTime.utc_now()
      )

    # A job can settle while the session is idle, after its last save.
    {:noreply,
     state
     |> Map.put(:job_ledger, ledger)
     |> release_job_admission(job_id)
     |> schedule_save()
     |> wake_for_job_notices()}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{job_owner_ref: ref} = state
      )
      when is_reference(ref) do
    {:noreply, state |> replace_job_owner() |> wake_for_job_notices()}
  end

  def handle_info({:job_unstarted, job_id}, state) do
    {:noreply, state |> settle_unstarted_job(job_id) |> wake_for_job_notices()}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{job_admissions: admissions} = state)
      when is_map_key(admissions, ref) do
    {job_id, admissions} = Map.pop!(admissions, ref)
    {:noreply, abandon_job(%{state | job_admissions: admissions}, job_id)}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    {:noreply, handle_question_worker_down(state, pid, ref, reason)}
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
      :stale -> {:noreply, state}
      {:save, persistence} -> save_session(state, persistence)
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @spec save_session(state(), Persistence.t()) :: {:noreply, state()}
  defp save_session(state, persistence) do
    state = %{state | persistence: persistence}
    previous_durable_revision = state.continuation.durable_revision
    {candidate, recovered_turn?} = recover_durable_retry(state)
    candidate = durable_save_candidate(candidate)

    case save_to_disk(candidate) do
      :ok ->
        finish_successful_save(
          candidate,
          persistence,
          recovered_turn?,
          previous_durable_revision,
          TurnExecution.display_status(state.turn_execution)
        )

      {:error, reason} ->
        Minga.Log.error(
          :agent,
          "[Agent.Session] failed to save session #{state.session_id} to disk: #{inspect(reason)}"
        )

        {:noreply, schedule_save_retry(state)}
    end
  end

  @spec finish_successful_save(
          state(),
          Persistence.t(),
          boolean(),
          non_neg_integer(),
          TurnExecution.display_status()
        ) :: {:noreply, state()}
  defp finish_successful_save(
         candidate,
         persistence,
         recovered_turn?,
         previous_durable_revision,
         previous_display_status
       ) do
    state = %{candidate | persistence: Persistence.saved(persistence)}

    state =
      announce_display_status_change(
        state,
        previous_display_status,
        TurnExecution.display_status(state.turn_execution)
      )

    state =
      if recovered_turn? do
        state
        |> broadcast(:messages_changed)
        |> announce_turn_status(state.turn_execution)
      else
        state
      end

    {:noreply, maybe_publish_resumable_boundary(state, previous_durable_revision)}
  end

  @spec reply_to_continue(state(), TurnExecution.t() | nil) :: {:reply, term(), state()}
  defp reply_to_continue(state, proposed_execution) do
    content =
      "Your previous response was interrupted mid-stream. Please continue from where you left off. Do not repeat what you already said."

    if function_exported?(state.provider.module, :continue, 2) do
      continue_provider_request(state, proposed_execution, content)
    else
      {:reply, {:error, "Provider does not support continue"}, state}
    end
  end

  @spec continue_provider_request(state(), TurnExecution.t() | nil, String.t()) ::
          {:reply, term(), state()}
  defp continue_provider_request(state, proposed_execution, content) do
    case begin_provider_request(state, content) do
      {:ok, request, request_state} ->
        dispatch_continue_request(state, request_state, request, proposed_execution)

      {:error, reason, failed_state} ->
        {:reply, {:error, reason}, failed_state}
    end
  end

  @spec dispatch_continue_request(state(), state(), Request.t(), TurnExecution.t() | nil) ::
          {:reply, term(), state()}
  defp dispatch_continue_request(state, request_state, request, proposed_execution) do
    case state.provider.module.continue(ProviderLifecycle.pid(state.provider), request) do
      :ok ->
        {:reply, :ok, finish_continue(request_state, proposed_execution, :ok)}

      {:error, reason} ->
        {:error, reason, failed_state} =
          persist_provider_dispatch_failure(request_state, reason)

        {:reply, {:error, reason}, finish_continue(failed_state, proposed_execution, :error)}
    end
  end

  @spec finish_continue(state(), TurnExecution.t() | nil, term()) :: state()
  defp finish_continue(state, %TurnExecution{} = execution, :ok) do
    state = announce_display_status(state, execution)
    %{state | turn_execution: execution}
  end

  defp finish_continue(state, _proposed_execution, _result), do: state

  @spec active_turn_target(state()) :: {String.t(), String.t()} | nil
  defp active_turn_target(%{provider: provider}) when ProviderLifecycle.is_detached(provider),
    do: nil

  defp active_turn_target(%{
         session_id: session_id,
         continuation: %Continuation{active_request: %Request{request_id: request_id}},
         turn_execution: execution
       }) do
    if TurnExecution.active?(execution), do: {session_id, request_id}
  end

  defp active_turn_target(_state), do: nil

  @spec active_turn_request_id(state()) :: String.t() | nil
  defp active_turn_request_id(state) do
    case active_turn_target(state) do
      {_session_id, request_id} -> request_id
      nil -> nil
    end
  end

  @spec stop_active_turn(state()) :: {:reply, :ok, state()}
  defp stop_active_turn(state),
    do: {:reply, :ok, abort_turn(state, &TurnExecution.stop/1, "Stopped")}

  @spec abort_turn(state()) :: state()
  defp abort_turn(state), do: abort_turn(state, &TurnExecution.abort/1, "Aborted")

  @spec abort_turn(state(), (TurnExecution.t() -> TurnExecution.t()), String.t()) :: state()
  defp abort_turn(state, transition, notice) do
    source_execution = state.turn_execution
    execution = transition.(source_execution)

    state =
      state
      |> cancel_waiting_tool(source_execution)
      |> interrupt_execution_approval(source_execution)
      |> interrupt_question()
      |> abort_provider()
      |> abort_active_tools(source_execution, false)
      |> cancel_provider_request()
      |> reconcile_interrupted_checkpoint()
      |> append_system_message(notice, :info)
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
      |> interrupt_execution_approval(source_execution)
      |> append_system_message(plan_mode_message(), :info)
      |> notify_messages_changed()
      |> broadcast({:status_changed, :plan})
      |> announce_display_status(execution)
      |> maybe_schedule_idle_gc(execution)

    revise_tool_policy(state, execution)
  end

  @spec enter_exec_mode(state(), TurnExecution.t()) :: state()
  defp enter_exec_mode(state, execution) do
    state =
      state
      |> append_system_message(exec_mode_message(), :info)
      |> notify_messages_changed()
      |> announce_turn_status(execution)

    revise_tool_policy(state, execution)
  end

  @spec queued_send_failed(state(), TurnExecution.t(), term()) :: state()
  defp queued_send_failed(state, proposed_execution, reason) do
    {:ok, execution} = TurnExecution.queued_send_failed(proposed_execution)
    state = %{state | turn_execution: execution}

    case reason do
      {:conversation_persistence_failed, _} ->
        state = notify(state, :error, @boundary_save_failure_message)
        {:reply, {:error, ^reason}, state} = reply_to_prompt_admission_failure(state, reason)
        state

      _ ->
        report_turn_error(state, "Could not start the queued turn: #{format_error(reason)}")
    end
  end

  @spec complete_provider_turn(state(), Event.token_usage() | nil, Outcome.t() | nil) :: state()
  defp complete_provider_turn(state, usage, outcome) do
    state = interrupt_question(state)
    source_execution = state.turn_execution

    case TurnExecution.begin_completion(source_execution) do
      {:ok, completing} ->
        state =
          state
          |> interrupt_execution_approval(source_execution)
          |> collapse_transcript_thinking()
          |> apply_turn_usage(usage)

        {state, outcome_result} = apply_provider_outcome(state, outcome)
        {state, boundary_result} = persist_completed_boundary(state)

        case {outcome_result, boundary_result} do
          {:accepted, :ok} ->
            lift_usage_limit(state)
            finish_provider_turn(state, completing)

          {:accepted, {:error, _reason}} ->
            fail_completed_turn(
              state,
              completing,
              "The turn finished in memory but could not be saved. Its result is not yet durable."
            )

          {{:reported, message}, _boundary_result} ->
            settle_reported_failure(state, completing, message)

          {{:interrupted, message}, _boundary_result} ->
            fail_completed_turn(state, completing, message)

          {{:rejected, message}, _boundary_result} ->
            fail_completed_turn(state, completing, message)
        end

      {:error, :invalid_phase} ->
        state
    end
  end

  @spec fail_completed_turn(state(), TurnExecution.t(), String.t()) :: state()
  defp fail_completed_turn(state, completing, message) do
    execution = TurnExecution.fail(completing, message)

    state
    |> mark_unsaved_active_tools()
    |> notify(:error, message)
    |> announce_turn_status(execution)
    |> append_error_message_once(message)
    |> notify_messages_changed()
    |> broadcast({:error, message})
    |> Map.put(:turn_execution, execution)
  end

  # The provider error event already reported this failure through report_turn_error/2, which owns its
  # transcript message, notification, and error broadcast. Completion only settles the turn.
  @spec settle_reported_failure(state(), TurnExecution.t(), String.t()) :: state()
  defp settle_reported_failure(state, completing, message) do
    execution = TurnExecution.fail(completing, message)

    state
    |> mark_unsaved_active_tools()
    |> announce_turn_status(execution)
    |> notify_messages_changed()
    |> Map.put(:turn_execution, execution)
  end

  @spec mark_unsaved_active_tools(state()) :: state()
  defp mark_unsaved_active_tools(state) do
    transcript =
      Enum.reduce(TurnExecution.active_tools(state.turn_execution), state.transcript, fn
        {id, _name}, transcript ->
          Transcript.update_tool_call(transcript, id, fn tool ->
            ToolCall.error(tool, indeterminate_tool_text(tool.result), tool.output)
          end)
      end)

    %{state | transcript: transcript}
  end

  defp indeterminate_tool_text(""),
    do: "Outcome indeterminate after interruption; the tool was not rerun."

  defp indeterminate_tool_text(partial),
    do: "Outcome indeterminate after interruption; the tool was not rerun.\n\n" <> partial

  @spec apply_provider_outcome(state(), Outcome.t() | nil) ::
          {state(),
           :accepted
           | {:reported, String.t()}
           | {:interrupted, String.t()}
           | {:rejected, String.t()}}
  defp apply_provider_outcome(state, nil) do
    continuation = Continuation.interrupt_request(state.continuation)
    state = %{state | continuation: continuation} |> reconcile_interrupted_checkpoint()

    case TurnExecution.error(state.turn_execution) do
      nil -> {state, {:interrupted, "Agent response ended before a continuation was returned."}}
      reported -> {state, {:reported, reported}}
    end
  end

  defp apply_provider_outcome(state, %Outcome{} = outcome) do
    transcript_id = boundary_transcript_id(state.transcript)

    case Continuation.complete(state.continuation, outcome, transcript_id) do
      {:ok, continuation} ->
        {%{state | continuation: continuation} |> freeze_checklist(transcript_id), :accepted}

      {:error, reason} ->
        state = cancel_provider_request(state)

        state =
          if state.continuation.tool_checkpoint do
            reconcile_interrupted_checkpoint(state)
          else
            state
          end

        message =
          "Provider outcome was rejected (#{inspect(reason)}). The active request was canceled and the last durable continuation was preserved."

        {state, {:rejected, message}}
    end
  end

  @spec freeze_checklist(state(), pos_integer()) :: state()
  defp freeze_checklist(state, transcript_id) do
    archive = ChecklistArchive.record(state.checklist_archive, transcript_id, state.checklist)
    %{state | checklist_archive: archive}
  end

  @spec boundary_transcript_id(Transcript.t()) :: pos_integer()
  defp boundary_transcript_id(transcript) do
    entries = Enum.reverse(Transcript.messages_with_ids(transcript))
    [{fallback_id, _message} | _rest] = entries

    Enum.find_value(entries, fallback_id, fn
      {_id, {:usage, _usage}} -> nil
      {id, _message} -> id
    end)
  end

  @spec reconcile_interrupted_checkpoint(state()) :: state()
  defp reconcile_interrupted_checkpoint(
         %{continuation: %Continuation{tool_checkpoint: nil}} = state
       ),
       do: state

  defp reconcile_interrupted_checkpoint(state) do
    if Enum.any?(state.tool_authority.invocations, fn {_key, entry} ->
         not is_nil(entry.failure)
       end) do
      state
    else
      case reconciliation_outputs(state) do
        {:ok, outputs} ->
          finish_interrupted_checkpoint_reconciliation(state, outputs)

        {:error, reason} ->
          state
          |> append_error_message_once(
            "Interrupted effect reconciliation could not inspect retained delivery state. The durable checkpoint was preserved; reload the session to retry safely."
          )
          |> broadcast({:error, "Effect reconciliation failed: #{inspect(reason)}"})
      end
    end
  end

  @spec finish_interrupted_checkpoint_reconciliation(
          state(),
          %{optional(String.t()) => Output.t()}
        ) :: state()
  defp finish_interrupted_checkpoint_reconciliation(state, outputs) do
    transcript_id = boundary_transcript_id(state.transcript)

    {continuation, reconciliation} =
      Continuation.reconcile_interrupted(
        state.continuation,
        transcript_id,
        outputs
      )

    indeterminate_count = Enum.count(reconciliation, &(&1.status == :indeterminate))
    not_executed_count = Enum.count(reconciliation, &(&1.status == :not_executed))

    candidate =
      state
      |> Map.put(:continuation, continuation)
      |> freeze_checklist(transcript_id)
      |> reconcile_transcript_tool_calls(reconciliation)
      |> append_system_message(
        "Interrupted tool-call group reconciled without replay: " <>
          "#{indeterminate_count} admitted call(s) are indeterminate and " <>
          "#{not_executed_count} unadmitted call(s) were not executed.",
        if(indeterminate_count == 0, do: :info, else: :error)
      )

    case commit_effect_snapshot(state, candidate) do
      {:ok, committed} ->
        committed

      {:error, reason} ->
        state
        |> append_error_message_once(
          "Interrupted effect reconciliation could not be saved. Further model execution is blocked; reload the session to retry safely."
        )
        |> broadcast({:error, "Effect reconciliation save failed: #{inspect(reason)}"})
    end
  end

  @spec reconcile_transcript_tool_calls(state(), [map()]) :: state()
  defp reconcile_transcript_tool_calls(state, reconciliation) do
    transcript =
      Enum.reduce(reconciliation, state.transcript, fn result, transcript ->
        Transcript.update_tool_call(transcript, result.tool_call_id, fn tool_call ->
          {:tool_call, reconciled} = reconcile_transcript_tool_call(tool_call, result)
          reconciled
        end)
      end)

    %{state | transcript: transcript}
  end

  @spec reconcile_transcript_tool_call(ToolCall.t(), map() | nil) :: Message.t()
  defp reconcile_transcript_tool_call(
         tool_call,
         %{
           status: status,
           result_message: %ReqLLM.Message{metadata: metadata} = result_message
         }
       )
       when status in [:completed, :indeterminate, :not_executed] do
    result = result_message_text(result_message)
    output = Map.get(metadata || %{}, :output)

    result =
      if status != :completed and output == nil and tool_call.result != "" do
        result <> "\n\nPrevious tool result:\n" <> tool_call.result
      else
        result
      end

    case ToolCall.saved_outcome(metadata || %{}) do
      {:ok, :error, nil} when status == :not_executed ->
        {:tool_call, ToolCall.reconcile_not_executed(tool_call, result, output)}

      {:ok, outcome, reason} ->
        {:tool_call, ToolCall.reconcile(tool_call, outcome, reason, result, output)}

      {:error, :invalid_tool_outcome} ->
        {:tool_call, ToolCall.reconcile(tool_call, :error, nil, result, output)}
    end
  end

  defp reconcile_transcript_tool_call(tool_call, _unrelated), do: {:tool_call, tool_call}

  @spec reconciliation_outputs(state()) ::
          {:ok, %{optional(String.t()) => Output.t()}} | {:error, term()}
  defp reconciliation_outputs(%{continuation: %Continuation{tool_checkpoint: checkpoint}} = state) do
    with {:ok, store} <- ensure_artifact_store(state) do
      Enum.reduce_while(checkpoint.calls, {:ok, %{}}, fn call, acc ->
        reconcile_checkpoint_call(store, checkpoint, call, acc)
      end)
    end
  rescue
    ArgumentError -> {:error, :artifact_runtime_unavailable}
  catch
    :exit, reason -> {:error, {:artifact_runtime_unavailable, reason}}
  end

  @spec reconcile_checkpoint_call(GenServer.server(), map(), map(), {:ok, map()}) ::
          {:cont, {:ok, map()}} | {:halt, {:error, term()}}
  defp reconcile_checkpoint_call(store, checkpoint, call, acc) do
    identity = {checkpoint.request_id, checkpoint.checkpoint_id, call.tool_call_id}

    case FileChange.reconcile_delivery(store, identity) do
      :ok -> reconcile_delivery_output(call, acc, store, checkpoint.checkpoint_id)
      {:error, _reason} = error -> {:halt, error}
    end
  end

  @spec reconcile_delivery_output(map(), {:ok, map()}, GenServer.server(), String.t()) ::
          {:cont, {:ok, map()}} | {:halt, {:error, term()}}
  defp reconcile_delivery_output(
         %{status: :admitted} = call,
         {:ok, outputs},
         store,
         checkpoint_id
       ) do
    case ArtifactStore.lookup_delivery(store, {:delivery, checkpoint_id, call.tool_call_id}) do
      {:ok, stored} ->
        {:cont, {:ok, Map.put(outputs, call.tool_call_id, indeterminate_output(stored))}}

      {:error, :unknown_delivery} ->
        {:cont, {:ok, outputs}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp reconcile_delivery_output(_call, acc, _store, _checkpoint_id), do: {:cont, acc}

  @spec indeterminate_output(MingaAgent.ArtifactStore.Stored.t()) :: Output.t()
  defp indeterminate_output(stored) do
    reference = stored.reference
    count = reference.items || reference.bytes
    unit = if reference.items == nil, do: :bytes, else: :items
    kind = if stored.capture == :complete, do: :full, else: :captured_prefix
    total = if stored.capture == :complete, do: count, else: :unknown
    {:ok, selection} = Range.new(kind, unit, 0, count, total)

    presentation =
      if reference.bytes == 0, do: :complete, else: {:truncated, :unknown}

    {:ok, output} =
      Output.new(
        "A retained producer capture exists, but effect completion is indeterminate.",
        stored.capture,
        selection,
        reference: reference,
        presentation: presentation
      )

    output
  end

  @spec result_message_text(ReqLLM.Message.t()) :: String.t()
  defp result_message_text(%ReqLLM.Message{content: content}) when is_binary(content),
    do: content

  defp result_message_text(%ReqLLM.Message{content: content}) when is_list(content) do
    Enum.map_join(content, "", fn
      %ReqLLM.Message.ContentPart{type: :text, text: text} when is_binary(text) -> text
    end)
  end

  @spec persist_completed_boundary(state()) :: {state(), :ok | {:error, term()}}
  defp persist_completed_boundary(state) do
    if Persistence.enabled?(state.persistence) and
         (not Continuation.durable?(state.continuation) or
            not is_nil(state.continuation.active_request)) do
      candidate = %{state | continuation: Continuation.mark_durable(state.continuation)}
      persist_boundary_candidate(state, candidate)
    else
      {state, :ok}
    end
  end

  @typep draft_admission :: :preserve | SessionStore.draft_admission()
  @spec persist_boundary_candidate(state(), state(), draft_admission()) ::
          {state(), :ok | {:error, term()}}
  defp persist_boundary_candidate(state, candidate, draft_revision \\ :preserve) do
    draft_revision = snapshot_write_mode(state, candidate, draft_revision)

    case save_to_disk(candidate, draft_revision) do
      :ok ->
        {persistence, timer_to_cancel} = Persistence.cancel(candidate.persistence)
        cancel_runtime_timer(timer_to_cancel)

        persisted = %{candidate | persistence: Persistence.saved(persistence)}
        {announce_resumable_boundary(persisted, candidate.continuation), :ok}

      {:error, {:draft_commit_uncertain, :admit_draft, _, _}} = error ->
        {state, error}

      {:error, reason} ->
        Minga.Log.error(
          :agent,
          "[Agent.Session] failed to commit resumable boundary #{state.session_id}: #{inspect(reason)}"
        )

        failed =
          state
          |> append_error_message_once(@boundary_save_failure_message)
          |> broadcast(:messages_changed)
          |> broadcast({:error, "Conversation save failed: #{inspect(reason)}"})
          |> schedule_save_retry()

        {failed, {:error, reason}}
    end
  end

  @spec announce_resumable_boundary(state(), Continuation.t()) :: state()
  defp announce_resumable_boundary(state, %Continuation{active_request: nil} = continuation),
    do: broadcast(state, {:resumable_boundary, continuation.revision})

  defp announce_resumable_boundary(state, %Continuation{}), do: state

  @spec commit_conversation_transition(state(), state()) ::
          {:ok, state()} | {:error, term(), state()}
  defp commit_conversation_transition(previous, candidate) do
    case commit_session_transition(previous, candidate) do
      {:ok, committed} ->
        {:ok, committed |> invalidate_connection(:conversation) |> publish_connection()}

      {:error, reason, failed} ->
        {:error, reason, failed}
    end
  end

  @spec commit_session_transition(state(), state()) ::
          {:ok, state()} | {:error, term(), state()}
  defp commit_session_transition(previous, candidate) do
    case persist_session_transition(candidate) do
      {:ok, committed} ->
        {:ok, broadcast(committed, :messages_changed)}

      {:error, reason} ->
        {:error, reason, report_session_transition_failure(previous, reason)}
    end
  end

  @spec persist_session_transition(state()) :: {:ok, state()} | {:error, term()}
  defp persist_session_transition(state) do
    if Persistence.enabled?(state.persistence) do
      candidate = durable_save_candidate(state)

      case save_to_disk(candidate) do
        :ok ->
          {persistence, timer_to_cancel} = Persistence.cancel(candidate.persistence)
          cancel_runtime_timer(timer_to_cancel)
          {:ok, %{candidate | persistence: Persistence.saved(persistence)}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, state}
    end
  end

  @spec report_session_transition_failure(state(), term()) :: state()
  defp report_session_transition_failure(state, reason) do
    message =
      "Conversation save failed. The previous durable conversation remains available; this change was not saved."

    Minga.Log.error(
      :agent,
      "[Agent.Session] failed to persist session transition: #{inspect(reason)}"
    )

    state
    |> append_error_message_once(message)
    |> broadcast({:error, "Conversation save failed: #{inspect(reason)}"})
    |> notify_messages_changed()
  end

  @spec collapse_transcript_thinking(state()) :: state()
  defp collapse_transcript_thinking(state) do
    %{state | transcript: Transcript.collapse_thinking(state.transcript)}
  end

  @spec finish_provider_turn(state(), TurnExecution.t()) :: state()
  defp finish_provider_turn(state, completing) do
    case TurnExecution.finish_completion(completing) do
      {:idle, execution} ->
        state =
          state
          |> notify(:complete, completion_notification(state))
          |> dispatch_stop()
          |> announce_turn_status(execution)

        wake_for_job_notices(%{state | turn_execution: execution})

      {:send_next, contents, execution} ->
        dispatch_notification(state, :complete, completion_notification(state))
        state |> dispatch_stop() |> send_queued_turn(contents, execution)
    end
  end

  # A request that succeeds on a route lifts its usage limit for every session on that route.
  @spec lift_usage_limit(state()) :: :ok
  defp lift_usage_limit(state),
    do: InferenceRouteRegistry.usage_limit_lifted(route_registry(state), state.model_selection)

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
      |> interrupt_execution_approval(source_execution)
      |> interrupt_question()
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
        |> interrupt_execution_approval(source_execution)
        |> interrupt_question()
        |> abort_provider()
        |> abort_active_tools(source_execution, true)
      else
        state
      end

    state = announce_display_status(state, execution)

    %{state | turn_execution: execution}
  end

  @spec announce_turn_status(state(), TurnExecution.t()) :: state()
  defp announce_turn_status(state, execution) do
    next_target = displayed_queue_target(%{state | turn_execution: execution})

    state =
      state
      |> announce_display_status(execution)
      |> broadcast({:queue_target_changed, next_target})

    case TurnExecution.mode(execution) do
      :exec ->
        state
        |> broadcast({:status_changed, TurnExecution.status(execution)})
        |> maybe_schedule_idle_gc(execution)

      :plan ->
        maybe_schedule_idle_gc(state, execution)
    end
  end

  @spec announce_display_status(state(), TurnExecution.t()) :: state()
  defp announce_display_status(state, execution) do
    previous = TurnExecution.display_status(state.turn_execution)
    next = TurnExecution.display_status(execution)

    state
    |> announce_display_status_change(previous, next)
    |> broadcast({:stop_target_changed, active_turn_target(%{state | turn_execution: execution})})
  end

  @spec announce_display_status_change(
          state(),
          TurnExecution.display_status(),
          TurnExecution.display_status()
        ) :: state()
  defp announce_display_status_change(state, status, status), do: state

  defp announce_display_status_change(state, _previous, next),
    do: broadcast(state, {:display_status_changed, next})

  @spec cancel_waiting_tool(state(), TurnExecution.t()) :: state()
  defp cancel_waiting_tool(state, execution) do
    case TurnExecution.pending_approval(execution) do
      %ToolApproval{tool_call_id: id} = approval ->
        case cancel_waiting_checkpoint(state, approval) do
          {:ok, candidate} ->
            transcript =
              Transcript.update_tool_call(
                candidate.transcript,
                id,
                &ToolCall.cancel(&1, "Cancelled before approval")
              )

            %{candidate | transcript: transcript}

          {:already_completed, result} ->
            install_saved_tool_result(state, id, result)

          {:error, reason} ->
            append_system_message(
              state,
              "Stop could not establish tool non-execution: #{inspect(reason)}",
              :error
            )
        end

      nil ->
        state
    end
  end

  @spec cancel_waiting_checkpoint(state(), ToolApproval.t()) ::
          {:ok, state()} | {:already_completed, ReqLLM.Message.t()} | {:error, term()}
  defp cancel_waiting_checkpoint(
         %{continuation: %Continuation{tool_checkpoint: nil}} = state,
         _approval
       ),
       do: {:ok, state}

  defp cancel_waiting_checkpoint(
         %{
           continuation: %Continuation{
             active_request: %Request{} = request,
             tool_checkpoint: checkpoint
           }
         } = state,
         approval
       ) do
    case Continuation.cancel_unadmitted_tool(
           state.continuation,
           request.request_id,
           checkpoint.checkpoint_id,
           approval.tool_call_id
         ) do
      {:ok, continuation} -> {:ok, %{state | continuation: continuation}}
      {:already_completed, _result} = saved -> saved
      {:error, _reason} = error -> error
    end
  end

  defp cancel_waiting_checkpoint(_state, _approval), do: {:error, :stale_request}

  @spec interrupt_execution_approval(state(), TurnExecution.t()) :: state()
  defp interrupt_execution_approval(state, execution) do
    case TurnExecution.pending_approval(execution) do
      %ToolApproval{} = approval ->
        {state, approval, :interrupted}
        |> reject_pending_approval()
        |> record_approval_resolution()
        |> broadcast_approval_retirement()

      nil ->
        state
    end
  end

  @spec send_approval_response(approval_resolution()) :: approval_resolution()
  defp send_approval_response({state, approval, decision}) do
    send_approval_response(approval, decision)
    {state, approval, decision}
  end

  @spec send_approval_response(ToolApproval.t(), approval_decision()) :: :ok
  defp send_approval_response(approval, decision) do
    send(
      approval.reply_to,
      {:tool_approval_response, approval.tool_call_id, execution_decision(decision)}
    )

    :ok
  end

  @spec record_approval_resolution(approval_retirement()) :: approval_retirement()
  defp record_approval_resolution({state, approval, decision} = resolution) do
    record_critical_event(state, :approval_resolved, %{
      approval_id: approval.tool_call_id,
      tool_call_id: approval.tool_call_id,
      session_id: state.session_id,
      request_id: state.continuation.active_request.request_id,
      name: approval.name,
      decision: decision
    })

    resolution
  end

  @spec maybe_append_approval_rejection(approval_resolution()) :: state()
  defp maybe_append_approval_rejection({state, approval, :reject}) do
    transcript =
      Transcript.update_tool_call(state.transcript, approval.tool_call_id, fn tool ->
        ToolCall.deny(tool, "Tool rejected by user")
      end)

    %{state | transcript: transcript}
    |> append_system_message(
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

    state
    |> broadcast({:tool_started, event.tool_call_id, event.name, event.args})
    |> notify_messages_changed()
  end

  @spec finish_tool(state(), Event.ToolEnd.t(), ToolCall.t()) :: state()
  defp finish_tool(state, event, completed_tool) do
    transcript =
      Transcript.update_tool_call(state.transcript, event.tool_call_id, fn _tool_call ->
        completed_tool
      end)

    state = %{state | transcript: transcript}
    status = event.outcome

    record_critical_event(state, :tool_call_finished, %{
      tool_call_id: event.tool_call_id,
      name: event.name,
      result: event.result,
      output: encode_output(event.output),
      status: status,
      reason: event.reason
    })

    state
    |> broadcast({:tool_ended, event})
    |> notify_messages_changed()
  end

  defp record_tool_terminal(tool, %Event.ToolEnd{outcome: :complete} = event),
    do: ToolCall.complete(tool, event.result, event.output)

  defp record_tool_terminal(tool, %Event.ToolEnd{outcome: :denied} = event),
    do: ToolCall.deny(tool, event.result, event.output)

  defp record_tool_terminal(tool, %Event.ToolEnd{outcome: :cancelled} = event),
    do: ToolCall.cancel(tool, event.result, event.output)

  defp record_tool_terminal(
         tool,
         %Event.ToolEnd{outcome: :error, reason: :approval_timeout} = event
       ),
       do: ToolCall.expire_approval(tool, event.result, event.output)

  defp record_tool_terminal(tool, %Event.ToolEnd{outcome: :error, reason: nil} = event),
    do: ToolCall.error(tool, event.result, event.output)

  @spec encode_output(Output.t() | nil) :: map() | nil
  defp encode_output(nil), do: nil
  defp encode_output(%Output{} = output), do: OutputCodec.encode(output)

  @spec steering_inputs([TurnExecution.content()]) :: {[ReqLLM.Message.t()], [Message.t()]}
  defp steering_inputs([]), do: {[], []}

  defp steering_inputs(inputs) do
    content = combine_queued_prompts(inputs)
    {display, _provider_input} = build_user_message(content)
    {[Context.user(content)], [display]}
  end

  # Cancels only the provider work admitted for the active request.
  # Without an active request the provider holds no Session-owned work, so there is nothing to cancel.
  @spec abort_provider(state()) :: state()
  defp abort_provider(
         %{continuation: %Continuation{active_request: %Request{request_id: request_id}}} = state
       ) do
    case ProviderLifecycle.pid(state.provider) do
      pid when is_pid(pid) -> state.provider.module.abort(pid, request_id)
      nil -> :ok
    end

    state
  end

  defp abort_provider(state), do: state

  @spec abort_active_tools(state(), TurnExecution.t(), boolean()) :: state()
  defp abort_active_tools(state, execution, notify?) do
    case TurnExecution.active_tools(execution) do
      [] ->
        state

      tools ->
        state =
          Enum.reduce(tools, state, fn {id, _name}, state ->
            transcript = Transcript.update_tool_call(state.transcript, id, &ToolCall.abort/1)
            state = %{state | transcript: transcript}
            record_critical_event(state, :tool_call_interrupted, %{tool_call_id: id})
            broadcast(state, {:tool_interrupted, id})
          end)

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
    combined = combine_queued_prompts(contents)
    {user_message, send_content} = build_user_message(combined)

    with {:ok, prepared} <- prepare_provider_request(state),
         candidate = append_msg(%{prepared | turn_execution: execution}, user_message),
         {:ok, request, admitted} <- admit_provider_request(prepared, candidate, send_content) do
      admitted =
        admitted
        |> record_user_message_event(user_message)
        |> notify_messages_changed()

      case send_admitted_prompt(admitted, request, execution) do
        {:ok, started} -> started
        {:error, reason, failed} -> queued_send_failed(failed, execution, reason)
      end
    else
      {:error, reason} -> retain_unconsumed_inputs(state, reason)
      {:error, reason, failed} -> retain_unconsumed_inputs(failed, reason)
    end
  end

  @spec retain_unconsumed_inputs(state(), term()) :: state()
  defp retain_unconsumed_inputs(state, reason) do
    state = %{state | turn_execution: TurnExecution.abort(state.turn_execution)}
    report_turn_error(state, "Queued input could not be admitted: #{inspect(reason)}")
  end

  @spec handle_approval_response(approval_target(), approval_decision(), state()) ::
          {:reply, :ok | {:error, approval_error()}, state()}
  defp handle_approval_response(
         %ApprovalTarget{
           session_id: session_id,
           request_id: request_id,
           tool_call_id: approval_id
         } = target,
         decision,
         %{
           session_id: session_id,
           continuation: %Continuation{active_request: %Request{request_id: request_id}}
         } = state
       ) do
    with :ok <- validate_approval_liveness(state, approval_id),
         {:ok, approval, execution} <-
           TurnExecution.resolve_approval(state.turn_execution, approval_id, decision) do
      Notifier.clear_approval()

      state =
        {state, approval, decision}
        |> approve_prepared_invocation()
        |> begin_approved_tool_execution()
        |> send_approval_response()
        |> record_approval_resolution()
        |> maybe_append_approval_rejection()
        |> notify_messages_changed()
        |> broadcast({:approval_resolved, target, decision})
        |> announce_display_status(execution)

      {:reply, :ok, %{state | turn_execution: execution}}
    else
      {:error, :approval_not_found} ->
        {:reply, {:error, :approval_not_found}, state}

      {:error, :no_pending_approval} ->
        Minga.Log.warning(:agent, "[Session] respond_to_approval called with no pending approval")
        {:reply, {:error, :no_pending_approval}, state}
    end
  end

  defp handle_approval_response(
         %ApprovalTarget{session_id: expected_session_id},
         _decision,
         %{session_id: current_session_id} = state
       )
       when expected_session_id != current_session_id,
       do: {:reply, {:error, :stale_session}, state}

  defp handle_approval_response(%ApprovalTarget{}, _decision, state),
    do: {:reply, {:error, :stale_request}, state}

  @spec validate_approval_liveness(state(), String.t()) ::
          :ok | {:error, :approval_not_found}
  defp validate_approval_liveness(
         %{continuation: %Continuation{active_request: %Request{request_id: request_id}}} =
           state,
         tool_call_id
       ) do
    invocation_ended? =
      Enum.any?(state.tool_authority.invocations, fn
        {{^request_id, _checkpoint_id, ^tool_call_id},
         %{started: started, approved: approved, failure: failure}} ->
          started or approved or not is_nil(failure)

        _other ->
          false
      end)

    if invocation_ended? or
         Continuation.tool_call_completed?(state.continuation, tool_call_id),
       do: {:error, :approval_not_found},
       else: :ok
  end

  defp validate_approval_liveness(_state, _tool_call_id),
    do: {:error, :approval_not_found}

  @spec handle_attached_prompt(
          state(),
          String.t(),
          [DraftAttachment.identity()],
          String.t() | [ReqLLM.Message.ContentPart.t()]
        ) :: {:reply, term(), state()} | {:stop, term(), term(), state()}
  defp handle_attached_prompt(state, record_id, shown, content) do
    with :ok <- validate_composer_record(state, record_id),
         false <- TurnExecution.active?(state.turn_execution),
         {:ok, revision, retained} <-
           SessionStore.resolve_draft_attachments(
             record_id,
             shown,
             state.session_store_dir,
             artifact_store_opts(state)
           ),
         {:ok, prompt} <-
           DraftAttachment.append_to_prompt(content, retained, state.model_selection) do
      handle_draft_prompt(state, prompt, revision)
    else
      true -> {:reply, {:error, :attachment_send_busy}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @spec handle_draft_prompt(
          state(),
          String.t() | [ReqLLM.Message.ContentPart.t()],
          SessionStore.draft_admission()
        ) ::
          {:reply, term(), state()} | {:stop, term(), term(), state()}
  defp handle_draft_prompt(state, prompt, admission) do
    case handle_prompt(prompt, :steering, state, admission) do
      {:reply,
       {:error,
        {:conversation_persistence_failed, {:draft_commit_uncertain, :admit_draft, _, _}} = reason},
       failed} ->
        {:stop, reason, {:error, reason}, failed}

      reply ->
        reply
    end
  end

  @spec handle_prompt(
          String.t() | [ReqLLM.Message.ContentPart.t()],
          TurnExecution.prompt_kind(),
          state(),
          draft_admission()
        ) :: {:reply, term(), state()}
  defp handle_prompt(content, kind, state, draft_revision \\ :preserve)

  defp handle_prompt(_content, _kind, %{credential_readiness: :checking} = state, _draft_revision) do
    {:reply, {:error, :credentials_pending}, state}
  end

  defp handle_prompt(_content, _kind, %{credentials_configured: false} = state, _draft_revision) do
    # No usable provider yet. Refuse locally so callers can preserve the draft instead of clearing it.
    {:reply, {:error, :credentials_not_configured}, state}
  end

  defp handle_prompt(
         content,
         kind,
         %{provider: provider} = state,
         draft_revision
       )
       when ProviderLifecycle.is_detached(provider) do
    {state, refresh_result} = refresh_credentials_state_result(state)

    case {ProviderLifecycle.pid(state.provider), refresh_result} do
      {_provider, {:error, reason}} ->
        {:reply, {:error, reason}, state}

      {nil, :ok} ->
        {:reply, {:error, :provider_not_ready}, state}

      {_provider, :ok} ->
        handle_prompt(content, kind, state, draft_revision)
    end
  end

  defp handle_prompt(content, kind, state, draft_revision) do
    case TurnExecution.admit_prompt(state.turn_execution, kind, content) do
      {:queued, _execution} when draft_revision != :preserve ->
        {:reply, {:error, :attachment_send_busy}, state}

      {:queued, execution} ->
        admit_queued_input(state, execution, kind, content)

      {:send_now, _execution} when is_map(state.continuation.tool_checkpoint) ->
        {:reply, {:error, :effect_reconciliation_required}, state}

      {:send_now, execution} ->
        send_new_turn(content, state, execution, draft_revision)

      {:error, :prompt_queue_full} = error ->
        {:reply, error, state}
    end
  end

  @spec admit_queued_input(
          state(),
          TurnExecution.t(),
          TurnExecution.prompt_kind(),
          TurnExecution.content()
        ) ::
          {:reply, {:queued, TurnExecution.prompt_kind()} | {:error, term()}, state()}
  defp admit_queued_input(state, execution, kind, content) do
    candidate = %{state | turn_execution: execution}

    case commit_effect_snapshot(state, candidate) do
      {:ok, committed} ->
        {:reply, {:queued, kind}, broadcast_queued_prompt(committed, content, kind)}

      {:error, reason} ->
        {:reply, {:error, {:queue_persistence_failed, reason}}, state}
    end
  end

  @spec queue_target_for_record(state(), String.t()) ::
          {:ok, queue_target()} | {:error, :not_persistent | :stale_target | :turn_not_active}
  defp queue_target_for_record(state, record_id) do
    with :ok <- validate_composer_record(state, record_id),
         true <- TurnExecution.active?(state.turn_execution),
         %Request{request_id: request_id} <- state.continuation.active_request do
      {next, _, _, _} = TurnExecution.pending_inputs(state.turn_execution)
      {:ok, {record_id, request_id, next}}
    else
      {:error, _reason} = error -> error
      _inactive -> {:error, :turn_not_active}
    end
  end

  @spec displayed_queue_target(state()) :: queue_target() | nil
  defp displayed_queue_target(state) do
    case queue_target_for_record(state, state.session_id) do
      {:ok, target} -> target
      {:error, _reason} -> nil
    end
  end

  @spec broadcast_queued_prompt(state(), TurnExecution.content(), TurnExecution.prompt_kind()) ::
          state()
  defp broadcast_queued_prompt(state, content, kind) do
    state
    |> broadcast({:queue_target_changed, displayed_queue_target(state)})
    |> broadcast({:prompt_queued, queued_preview(content), kind})
  end

  @spec queued_preview(TurnExecution.content()) :: String.t()
  defp queued_preview(content) when is_binary(content), do: content
  defp queued_preview(parts), do: combine_queue_entries_to_text([parts])

  @spec handle_queued_draft(
          state(),
          queue_target(),
          TurnExecution.prompt_kind(),
          queue_draft(),
          TurnExecution.content()
        ) :: {:reply, {:ok, TurnExecution.queue_receipt()} | {:error, term()}, state()}
  defp handle_queued_draft(
         state,
         {record_id, request_id, next},
         kind,
         {revision, submission_id, shown, source},
         content
       )
       when is_binary(record_id) and is_binary(request_id) and is_integer(next) and next > 0 and
              kind in [:steering, :follow_up] and is_integer(revision) and revision >= 0 and
              is_binary(submission_id) and byte_size(submission_id) == 24 and is_list(shown) and
              (is_binary(content) or is_list(content)) do
    with :ok <- validate_composer_record(state, record_id),
         :ok <- validate_queue_submission_id(submission_id),
         :new <- TurnExecution.queued_submission(state.turn_execution, next, submission_id),
         :ok <- validate_queue_request(state, request_id),
         {:ok, prompt, retained} <-
           resolve_queued_draft(state, revision, shown, {source, content}),
         attachments = Enum.map(retained, &elem(&1, 0)),
         {:ok, receipt, execution} <-
           TurnExecution.admit_queued_submission(
             state.turn_execution,
             kind,
             prompt,
             next,
             {submission_id, revision + 1},
             attachments,
             source
           ),
         candidate = %{state | turn_execution: execution},
         {:ok, committed} <- commit_effect_snapshot(state, candidate, {:queued_draft, revision}) do
      {:reply, {:ok, receipt}, broadcast_queued_prompt(committed, source, kind)}
    else
      {:queued, receipt} -> {:reply, {:ok, receipt}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  defp handle_queued_draft(state, _target, _kind, _draft, _content),
    do: {:reply, {:error, :invalid_queue_submission}, state}

  @spec validate_queue_submission_id(String.t()) :: :ok | {:error, :invalid_submission_id}
  defp validate_queue_submission_id(id) do
    if String.valid?(id), do: :ok, else: {:error, :invalid_submission_id}
  end

  @spec validate_queue_request(state(), String.t()) :: :ok | {:error, :stale_request}
  defp validate_queue_request(state, request_id) do
    if Continuation.accepts?(state.continuation, request_id),
      do: :ok,
      else: {:error, :stale_request}
  end

  @spec resolve_queued_draft(
          state(),
          non_neg_integer(),
          [DraftAttachment.identity()],
          {String.t(), TurnExecution.content()}
        ) ::
          {:ok, TurnExecution.content(), [{DraftSnapshot.attachment(), String.t()}]}
          | {:error, term()}
  defp resolve_queued_draft(state, revision, shown, {source, content}) do
    with true <- (is_binary(source) and String.valid?(source)) || {:error, :invalid_queue_text},
         {:ok, ^revision, retained} <-
           SessionStore.resolve_draft_attachments(
             state.session_id,
             shown,
             state.session_store_dir,
             artifact_store_opts(state)
           ),
         {:ok, prompt} <- queued_draft_content(content, retained, state.model_selection) do
      {:ok, prompt, retained}
    else
      {:ok, current, _retained} -> {:error, {:stale_draft_revision, current}}
      {:error, _reason} = error -> error
    end
  end

  @spec queued_draft_content(
          TurnExecution.content(),
          [{DraftSnapshot.attachment(), String.t()}],
          ModelSelection.t() | nil
        ) :: {:ok, TurnExecution.content()} | {:error, term()}
  defp queued_draft_content(content, [], _selection), do: {:ok, content}

  defp queued_draft_content(content, retained, selection),
    do: DraftAttachment.append_to_prompt(content, retained, selection)

  @spec pending_input_summaries(TurnExecution.t()) :: [QueuedInputSummary.t()]
  defp pending_input_summaries(execution) do
    {_next, steering, follow_up, _receipts} = TurnExecution.pending_inputs(execution)

    Enum.map(steering, &QueuedInputSummary.new(&1, :steering)) ++
      Enum.map(follow_up, &QueuedInputSummary.new(&1, :follow_up))
  end

  @spec queued_input_text_result(state(), String.t(), term()) ::
          {:ok, String.t()} | {:error, term()}
  defp queued_input_text_result(state, record, {id, revision})
       when is_integer(id) and id > 0 and is_integer(revision) and revision > 0 do
    with :ok <- validate_composer_record(state, record),
         do: TurnExecution.queued_editable_text(state.turn_execution, id, revision)
  end

  defp queued_input_text_result(_state, _record, _identity), do: {:error, :invalid_queue_edit}

  @spec change_queued_input_reply(state(), String.t(), pos_integer(), pos_integer(), term()) ::
          {:reply, :ok | {:error, term()}, state()}
  defp change_queued_input_reply(state, record_id, id, revision, operation)
       when operation == :remove or
              (is_tuple(operation) and tuple_size(operation) == 2 and
                 elem(operation, 0) == :replace_text and is_binary(elem(operation, 1))) or
              (is_tuple(operation) and tuple_size(operation) == 3 and
                 elem(operation, 0) == :replace_prompt and is_binary(elem(operation, 1)) and
                 (is_binary(elem(operation, 2)) or is_list(elem(operation, 2)))) do
    with :ok <- validate_composer_record(state, record_id),
         {:ok, execution} <-
           TurnExecution.change_queued_input(state.turn_execution, id, revision, operation),
         {:ok, committed} <- commit_effect_snapshot(state, %{state | turn_execution: execution}) do
      {:reply, :ok, broadcast(committed, :queues_recalled)}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  defp change_queued_input_reply(state, _record_id, _id, _revision, _operation),
    do: {:reply, {:error, :invalid_queue_edit}, state}

  @spec recall_composer_draft(
          state(),
          String.t(),
          non_neg_integer(),
          DraftSnapshot.t() | nil,
          :keep_running
        ) :: {{:ok, non_neg_integer(), DraftSnapshot.t()} | {:error, term()}, state()}
  defp recall_composer_draft(state, record_id, revision, draft, :keep_running),
    do: recall_composer_draft(state, record_id, revision, draft)

  defp recall_composer_draft(state, _record, _revision, _draft, _action),
    do: {{:error, :invalid_draft_snapshot}, state}

  @spec recall_composer_draft(state(), String.t(), non_neg_integer(), DraftSnapshot.t() | nil) ::
          {{:ok, non_neg_integer(), DraftSnapshot.t()} | {:error, term()}, state()}
  defp recall_composer_draft(state, record_id, revision, current) do
    with :ok <- validate_composer_record(state, record_id),
         {:ok, ^revision, prior} <- composer_draft(state, record_id, :read),
         :ok <- match_recalled_attachments(prior, current),
         {:ok, draft, execution} <- TurnExecution.recall_draft(state.turn_execution, current),
         candidate = %{state | turn_execution: execution},
         {:ok, committed} <-
           commit_effect_snapshot(state, candidate, {:recalled_draft, revision, draft}) do
      {{:ok, revision + 1, draft}, broadcast(committed, :queues_recalled)}
    else
      {:ok, latest_revision, _draft} ->
        {{:error, {:stale_draft_revision, latest_revision}}, state}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  @spec match_recalled_attachments(DraftSnapshot.t() | nil, DraftSnapshot.t() | nil) ::
          :ok | {:error, :draft_attachments_changed}
  defp match_recalled_attachments(%DraftSnapshot{attachments: attachments}, %DraftSnapshot{
         attachments: attachments
       }),
       do: :ok

  defp match_recalled_attachments(nil, %DraftSnapshot{attachments: []}), do: :ok
  defp match_recalled_attachments(%DraftSnapshot{attachments: []}, nil), do: :ok
  defp match_recalled_attachments(nil, nil), do: :ok
  defp match_recalled_attachments(_prior, _current), do: {:error, :draft_attachments_changed}

  @spec send_new_turn(
          String.t() | [ReqLLM.Message.ContentPart.t()],
          state(),
          TurnExecution.t(),
          draft_admission()
        ) :: {:reply, term(), state()}
  defp send_new_turn(content, state, execution, draft_revision) do
    case dispatch_user_prompt_submit(state, content) do
      :ok -> begin_new_turn(content, state, execution, draft_revision)
      {:error, %HookResult{} = result} -> reply_to_prompt_veto(state, result)
    end
  end

  @spec begin_new_turn(
          String.t() | [ReqLLM.Message.ContentPart.t()],
          state(),
          TurnExecution.t(),
          draft_admission()
        ) :: {:reply, term(), state()}
  defp begin_new_turn(content, state, execution, draft_revision) do
    case prepare_provider_request(state) do
      {:ok, prepared} ->
        admit_new_turn(content, prepared, execution, draft_revision)

      {:error, reason} ->
        reply_to_prompt_admission_failure(state, reason)
    end
  end

  @spec admit_new_turn(
          String.t() | [ReqLLM.Message.ContentPart.t()],
          state(),
          TurnExecution.t(),
          draft_admission()
        ) :: {:reply, term(), state()}
  defp admit_new_turn(content, state, execution, draft_revision) do
    {user_message, send_content} = build_user_message(content)
    candidate = append_msg(state, user_message)

    case admit_provider_request(state, candidate, send_content, draft_revision) do
      {:ok, request, admitted} ->
        admitted =
          admitted
          |> record_user_message_event(user_message)
          |> notify_messages_changed()

        dispatch_new_turn_request(admitted, request, execution)
        |> acknowledge_consumed_draft(draft_revision)

      {:error, reason, failed_state} ->
        reply_to_prompt_admission_failure(failed_state, reason)
    end
  end

  @spec acknowledge_consumed_draft({:reply, term(), state()}, draft_admission()) ::
          {:reply, term(), state()}
  defp acknowledge_consumed_draft(reply, :preserve), do: reply

  defp acknowledge_consumed_draft(reply, {revision, _submission_id}),
    do: acknowledge_consumed_draft(reply, revision)

  defp acknowledge_consumed_draft({:reply, :ok, state}, revision),
    do: {:reply, {:ok, revision + 1}, state}

  defp acknowledge_consumed_draft({:reply, {:error, reason}, state}, revision),
    do: {:reply, {:accepted, revision + 1, reason}, state}

  @spec dispatch_new_turn_request(state(), Request.t(), TurnExecution.t()) ::
          {:reply, :ok | {:error, term()}, state()}
  defp dispatch_new_turn_request(state, request, execution) do
    case send_admitted_prompt(state, request, execution) do
      {:ok, started} -> {:reply, :ok, started}
      {:error, reason, failed_state} -> reply_to_prompt_admission_failure(failed_state, reason)
    end
  end

  @spec send_admitted_prompt(state(), Request.t(), TurnExecution.t()) ::
          {:ok, state()} | {:error, term(), state()}
  defp send_admitted_prompt(state, request, execution) do
    case state.provider.module.send_prompt(ProviderLifecycle.pid(state.provider), request) do
      :ok ->
        state = announce_display_status(state, execution)
        {:ok, %{state | turn_execution: execution}}

      {:error, reason} ->
        persist_provider_dispatch_failure(state, reason)
    end
  end

  @spec reply_to_prompt_admission_failure(state(), term()) ::
          {:reply, {:error, term()}, state()}
  defp reply_to_prompt_admission_failure(
         state,
         {:conversation_persistence_failed, _reason} = reason
       ) do
    # The failed write already published its error and scheduled a retry; this is not another transcript edit.
    execution =
      case TurnExecution.error(state.turn_execution) do
        nil -> TurnExecution.report_error(state.turn_execution, @boundary_save_failure_message)
        _existing_error -> state.turn_execution
      end

    state = announce_turn_status(state, execution)
    {:reply, {:error, reason}, %{state | turn_execution: execution}}
  end

  defp reply_to_prompt_admission_failure(state, reason) do
    message = prompt_admission_failure_message(reason)
    Minga.Log.error(:agent, "[Agent.Session] #{message}")
    {:reply, {:error, reason}, report_turn_error(state, message)}
  end

  @spec prompt_admission_failure_message(term()) :: String.t()
  defp prompt_admission_failure_message(
         {:portable_context_transition_required, %{message: message}}
       )
       when is_binary(message),
       do: "#{message} Your draft was not sent and is preserved."

  defp prompt_admission_failure_message(reason) when is_binary(reason),
    do: "Prompt not sent: #{reason}. Your draft is preserved."

  defp prompt_admission_failure_message(reason),
    do: "Prompt not sent: #{inspect(reason)}. Your draft is preserved."

  @spec reply_to_prompt_veto(state(), HookResult.t()) :: {:reply, {:error, term()}, state()}
  defp reply_to_prompt_veto(state, result),
    do: {:reply, {:error, {:hook_veto, HookResult.message(result)}}, state}

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

  defp handle_provider_event(%Event.AgentEnd{usage: usage, outcome: outcome}, state),
    do: complete_provider_turn(state, usage, outcome)

  defp handle_provider_event(%Event.TextDelta{delta: delta}, state) do
    state
    |> Map.update!(:transcript, &Transcript.append_stream_tail(&1, :assistant, [delta]))
    |> broadcast({:text_delta, delta})
  end

  # Waiting, not failed: the tasks drawer counts down to the retry.
  defp handle_provider_event(%Event.RetryScheduled{delay_ms: delay_ms, reason: reason}, state),
    do: broadcast(state, {:retry_scheduled, delay_ms, reason})

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

  defp handle_provider_event(%Event.TodoPlan{}, state), do: state

  defp handle_provider_event(%Event.ToolApproval{} = event, state) do
    case validate_approval_liveness(state, event.tool_call_id) do
      :ok ->
        case {TurnExecution.error(state.turn_execution),
              TurnExecution.trusted_scope(state.turn_execution, event)} do
          {message, _scope} when is_binary(message) ->
            send(event.reply_to, {:tool_approval_response, event.tool_call_id, :reject})
            broadcast(state, {:approval_rejected, event.tool_call_id, event.name, message})

          {nil, nil} ->
            request_tool_approval(event, state)

          {nil, scope} ->
            auto_approve_tool(event, state, scope)
        end

      {:error, :approval_not_found} ->
        reject_stale_tool_approval(event, state)
    end
  end

  defp handle_provider_event(%Event.ToolUpdate{} = event, state) do
    handle_tool_update(event, state)
  end

  defp handle_provider_event(%Event.ToolEnd{} = event, state) do
    case Transcript.current_tool_call(state.transcript, event.tool_call_id) do
      %ToolCall{} = tool ->
        complete_provider_tool(state, event, record_tool_terminal(tool, event))

      nil ->
        state
    end
  end

  defp handle_provider_event(%Event.ContextUsage{} = event, state) do
    broadcast(
      state,
      {:context_usage, event.estimated_tokens, event.context_limit, event.reported_tokens,
       event.estimation_method}
    )
  end

  defp handle_provider_event(%Event.TurnLimitReached{current: current, limit: limit}, state) do
    broadcast(state, {:turn_limit_reached, current, limit})
  end

  defp handle_provider_event(%Event.Error{} = event, state) do
    state = retain_connection_error(state, event)
    observe_usage_limit(state, event)
    message = humanize_error(event, state)

    state
    |> report_turn_error(message)
    |> announce_model_limit(event, message)
  end

  # `/model` in every session shows the route as limit-reached until the reset passes or a later
  # request on it succeeds.
  @spec observe_usage_limit(state(), Event.Error.t()) :: :ok
  defp observe_usage_limit(state, %Event.Error{kind: :usage_limit_reached, usage_limit: limit}) do
    InferenceRouteRegistry.usage_limit_observed(
      route_registry(state),
      state.model_selection,
      limit
    )
  end

  defp observe_usage_limit(_state, %Event.Error{}), do: :ok

  # Only a usage-limit error offers a model switch; the draft stays as it is.
  @spec announce_model_limit(state(), Event.Error.t(), String.t()) :: state()
  defp announce_model_limit(state, %Event.Error{recovery: :choose_model}, message),
    do: broadcast(state, {:model_limit_reached, message})

  defp announce_model_limit(state, _event, _message), do: state

  @spec complete_provider_tool(state(), Event.ToolEnd.t(), ToolCall.t()) :: state()
  defp complete_provider_tool(
         state,
         %Event.ToolEnd{outcome: outcome, reason: reason, result: result, output: output} = event,
         %ToolCall{status: outcome, terminal_reason: reason, result: result, output: output} =
           tool
       ) do
    case TurnExecution.tool_completed(state.turn_execution, event) do
      {:ok, execution} ->
        state = finish_tool(state, event, tool)
        state = announce_display_status(state, execution)
        %{state | turn_execution: execution}

      {:error, :tool_not_active} ->
        state
    end
  end

  defp complete_provider_tool(state, _conflicting_event, _unchanged_tool), do: state

  defp reject_stale_tool_approval(%Event.ToolApproval{} = event, state) do
    reject_pending_approval(event)

    message = "This tool approval no longer has an active wait in its provider request."

    Minga.Log.warning(:agent, "Rejected stale tool approval for #{event.name}")
    broadcast(state, {:approval_rejected, event.tool_call_id, event.name, message})
  end

  defp reject_stale_tool_approval(_event, state), do: state
  @spec handle_tool_file_changed(Event.ToolFileChanged.t(), String.t(), state()) :: state()
  defp handle_tool_file_changed(event, tool_name, state) do
    state
    |> broadcast(
      {:file_changed, state.connection.conversation, event.path, event.before_content,
       event.after_content, event.tool_call_id, tool_name}
    )
    |> record_tool_file_preview(event)
    |> notify_messages_changed()
  end

  @spec handle_tool_update(Event.ToolUpdate.t(), state()) :: state()
  defp handle_tool_update(event, state) do
    transcript =
      Transcript.update_tool_call(state.transcript, event.tool_call_id, fn tool_call ->
        ToolCall.update_partial(tool_call, event.partial_result)
      end)

    if Transcript.revision(transcript) == Transcript.revision(state.transcript) do
      state
    else
      %{state | transcript: transcript}
      |> broadcast({:tool_update, event.tool_call_id, event.name, event.partial_result})
    end
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
        reply_to: event.reply_to,
        working_directory: event.working_directory
      )

    case TurnExecution.request_approval(state.turn_execution, approval) do
      {:accepted, execution} ->
        state =
          state
          |> notify(:approval, "Approval needed: #{approval.name}")
          |> broadcast({:approval_pending, public_pending_approval(approval, state)})
          |> announce_display_status(execution)

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
        {state, _approval, _decision} =
          {state, approval, :approve}
          |> approve_prepared_invocation()
          |> begin_approved_tool_execution()
          |> send_approval_response()

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

  @spec model_seed_messages([Message.t()]) ::
          {:ok, [ReqLLM.Message.t()]} | {:error, {:unsupported_seed_message, term()}}
  defp model_seed_messages(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn
      {:user, text}, {:ok, acc} when is_binary(text) ->
        {:cont, {:ok, [Context.user(text) | acc]}}

      {:assistant, text}, {:ok, acc} when is_binary(text) ->
        {:cont, {:ok, [Context.assistant(text) | acc]}}

      message, {:ok, _acc} ->
        {:halt, {:error, {:unsupported_seed_message, message}}}
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
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

  @spec public_pending_approval(ToolApproval.t() | nil, state()) :: PublicApproval.t() | nil
  defp public_pending_approval(nil, _state), do: nil

  defp public_pending_approval(
         %ToolApproval{} = approval,
         %{
           session_id: session_id,
           continuation: %Continuation{active_request: %Request{request_id: request_id}}
         }
       ) do
    target = ApprovalTarget.new(session_id, request_id, approval.tool_call_id)
    ToolApproval.public(approval, target)
  end

  @spec record_tool_file_preview(state(), Event.ToolFileChanged.t()) :: state()
  defp record_tool_file_preview(state, %Event.ToolFileChanged{} = event) do
    preview =
      ToolApproval.build_file_diff_preview(
        event.path,
        if(event.before_content == :absent, do: "", else: event.before_content),
        if(event.after_content == :absent, do: "", else: event.after_content)
      )

    transcript =
      Transcript.update_tool_call(state.transcript, event.tool_call_id, fn tool_call ->
        ToolCall.set_preview(tool_call, preview)
      end)

    %{state | transcript: transcript}
  end

  # ── Status management ──────────────────────────────────────────────────────

  @spec reject_pending_approval(
          pending_approval()
          | Event.tool_approval()
          | {state(), ToolApproval.t(), :interrupted}
        ) :: :ok | {state(), ToolApproval.t(), :interrupted}
  defp reject_pending_approval({_state, approval, :interrupted} = context) do
    reject_pending_approval(approval)
    context
  end

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

  # ── JobOwner lifecycle ────────────────────────────────────────────────────

  @spec maybe_start_job_owner(state(), boolean()) :: state()
  defp maybe_start_job_owner(state, false), do: state
  defp maybe_start_job_owner(state, true), do: start_job_owner(state)

  # Each JobOwner runs under a new epoch, so a report from an earlier owner can never settle a newer job.
  @spec start_job_owner(state()) :: state()
  defp start_job_owner(state) do
    epoch = state.job_epoch + 1
    {:ok, pid} = JobOwner.start_link(session: self(), epoch: epoch)
    ref = Process.monitor(pid)
    %{state | job_owner: pid, job_owner_ref: ref, job_epoch: epoch}
  end

  # The dead owner's tasks died with it, so its running jobs have no observed end.
  @spec replace_job_owner(state()) :: state()
  defp replace_job_owner(state) do
    Enum.each(Map.keys(state.job_admissions), &Process.demonitor(&1, [:flush]))
    ledger = JobLedger.interrupt_running(state.job_ledger, :owner_down, DateTime.utc_now())

    %{state | job_owner: nil, job_owner_ref: nil, job_ledger: ledger, job_admissions: %{}}
    |> start_job_owner()
    |> schedule_save()
  end

  # Installs the job ledger of the conversation that replaces the current one.
  #
  # Live jobs belong to the replaced conversation, so they are reaped. A replacement JobOwner runs
  # under a new epoch, so a report still in flight from the reaped owner is stale and cannot settle
  # a job of the installed ledger, even one that reuses an id.
  @spec install_job_ledger(state(), JobLedger.t()) :: state()
  defp install_job_ledger(state, %JobLedger{} = ledger) do
    Enum.each(Map.keys(state.job_admissions), &Process.demonitor(&1, [:flush]))
    state = %{state | job_ledger: ledger, job_admissions: %{}}

    case state.job_owner do
      nil ->
        state

      owner ->
        Process.demonitor(state.job_owner_ref, [:flush])
        reap_job_owner(owner)
        start_job_owner(%{state | job_owner: nil, job_owner_ref: nil})
    end
  end

  @spec release_job_admission(state(), JobRecord.id()) :: state()
  defp release_job_admission(state, job_id) do
    case Enum.find(state.job_admissions, fn {_ref, id} -> id == job_id end) do
      {ref, _id} ->
        Process.demonitor(ref, [:flush])
        %{state | job_admissions: Map.delete(state.job_admissions, ref)}

      nil ->
        state
    end
  end

  # The caller exited before a background job started or before a foreground job ended. A start
  # it sent before exiting is already queued at the owner ahead of this cancel, so the owner
  # cancels the job and reports the end.
  @spec abandon_job(state(), JobRecord.id()) :: state()
  defp abandon_job(state, job_id) do
    case JobLedger.fetch(state.job_ledger, job_id) do
      {:ok, %JobRecord{status: :running}} ->
        case cancel_owned_job(state, job_id) do
          :ok ->
            state

          {:error, :already_terminal} ->
            # Anything the owner reported about this job is already queued ahead of this check.
            send(self(), {:job_unstarted, job_id})
            state
        end

      _ended_or_evicted ->
        state
    end
  end

  # Runs after every earlier owner report, so a job still running here never reached the owner.
  @spec settle_unstarted_job(state(), JobRecord.id()) :: state()
  defp settle_unstarted_job(state, job_id) do
    case JobLedger.fetch(state.job_ledger, job_id) do
      {:ok, %JobRecord{status: :running, epoch: epoch}} ->
        ledger =
          JobLedger.settle(
            state.job_ledger,
            job_id,
            epoch,
            :cancelled,
            nil,
            %{reference: nil, preview: nil},
            DateTime.utc_now()
          )

        schedule_save(%{state | job_ledger: ledger})

      _ended_or_evicted ->
        state
    end
  end

  # A not-found owner reply means the job already ended and its settled report is queued here.
  @spec cancel_owned_job(state(), JobRecord.id()) :: :ok | {:error, :already_terminal}
  defp cancel_owned_job(%{job_owner: nil}, _job_id), do: {:error, :already_terminal}

  defp cancel_owned_job(%{job_owner: owner}, job_id) do
    case JobOwner.cancel(owner, job_id) do
      :ok -> :ok
      {:error, :job_not_found} -> {:error, :already_terminal}
    end
  catch
    # The owner died; its DOWN message interrupts the job.
    :exit, _reason -> {:error, :already_terminal}
  end

  @spec reap_job_owner(pid() | nil) :: :ok
  defp reap_job_owner(nil), do: :ok

  defp reap_job_owner(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      JobOwner.reap_all(pid)
      GenServer.stop(pid, :shutdown)
    end

    :ok
  end

  # Starts a host-origin request that carries every pending job notice, so an idle agent learns
  # that its background jobs ended without the user typing. The notices stay pending while a
  # turn, an approval, a question or a failure is outstanding; an active turn receives them at
  # its next checkpoint dispatch instead.
  @spec wake_for_job_notices(state()) :: state()
  defp wake_for_job_notices(state) do
    case JobLedger.pending_notices(state.job_ledger) do
      [] ->
        state

      records ->
        if notice_wake_ready?(state), do: start_job_notice_turn(state, records), else: state
    end
  end

  @spec notice_wake_ready?(state()) :: boolean()
  defp notice_wake_ready?(%{credential_readiness: :checking}), do: false
  defp notice_wake_ready?(%{credentials_configured: false}), do: false

  defp notice_wake_ready?(%{provider: provider}) when ProviderLifecycle.is_detached(provider),
    do: false

  defp notice_wake_ready?(
         %{continuation: %Continuation{active_request: nil, tool_checkpoint: nil}} = state
       ),
       do: TurnExecution.phase(state.turn_execution) == :idle

  defp notice_wake_ready?(_state), do: false

  @spec start_job_notice_turn(state(), [JobRecord.t(), ...]) :: state()
  defp start_job_notice_turn(state, records) do
    {:ok, execution} = TurnExecution.begin_turn(state.turn_execution)

    with {:ok, prepared} <- prepare_provider_request(state),
         turn_id = prepared.transcript.next_id,
         candidate = deliver_job_notices(prepared, records),
         {:ok, request, admitted} <-
           admit_host_request(prepared, candidate, JobNotice.message(records), turn_id) do
      case state.provider.module.send_prompt(ProviderLifecycle.pid(state.provider), request) do
        :ok ->
          admitted =
            admitted |> publish_job_notices(records) |> announce_display_status(execution)

          %{admitted | turn_execution: execution}

        {:error, reason} ->
          retract_job_notice_request(prepared, admitted, reason)
      end
    else
      {:error, reason} -> hold_job_notices(state, reason)
      {:error, reason, failed} -> hold_job_notices(failed, reason)
    end
  end

  # The provider refused the host request, so the model never saw the notices. The admission is
  # withdrawn as a whole: no active request, no notice entry, and the notices pending again. The
  # session reports a failure, so the notices wait for the next turn boundary instead of waking
  # the agent again at once.
  @spec retract_job_notice_request(state(), state(), term()) :: state()
  defp retract_job_notice_request(prepared, admitted, reason) do
    retracted = %{
      admitted
      | continuation: Continuation.cancel(admitted.continuation),
        job_ledger: prepared.job_ledger,
        transcript: prepared.transcript
    }

    state =
      case persist_session_transition(retracted) do
        {:ok, committed} -> committed
        {:error, save_reason} -> report_session_transition_failure(retracted, save_reason)
      end

    report_turn_error(
      state,
      "Could not deliver background job results to the agent: #{format_error(reason)}. They will be retried at the next turn boundary."
    )
  end

  # The admission did not commit, so the notices are still pending for the next boundary.
  @spec hold_job_notices(state(), term()) :: state()
  defp hold_job_notices(state, reason) do
    Minga.Log.warning(
      :agent,
      "[Agent.Session] background job notices held: #{inspect(reason)}"
    )

    state
  end

  # Marks the notices delivered and shows them as one system entry, in the state update that
  # freezes them into a dispatch or begins their host request, so they are saved together.
  @spec deliver_job_notices(state(), [JobRecord.t()]) :: state()
  defp deliver_job_notices(state, []), do: state

  defp deliver_job_notices(state, records) do
    ledger = JobLedger.mark_notices_delivered(state.job_ledger, Enum.map(records, & &1.id))
    append_msg(%{state | job_ledger: ledger}, Message.system(JobNotice.display_text(records)))
  end

  @spec publish_job_notices(state(), [JobRecord.t()]) :: state()
  defp publish_job_notices(state, []), do: state

  defp publish_job_notices(state, records) do
    record_critical_event(state, :system_message, %{
      message: JobNotice.display_text(records),
      level: :info
    })

    notify_messages_changed(state)
  end

  @spec job_notice_message([JobRecord.t()]) :: ReqLLM.Message.t() | nil
  defp job_notice_message([]), do: nil
  defp job_notice_message(records), do: JobNotice.message(records)

  # ── Subscriber lifecycle ──────────────────────────────────────────────────

  @spec subscribe_initial(state(), [{pid(), keyword()}], reference() | nil) :: state()
  defp subscribe_initial(state, [], _token), do: state

  defp subscribe_initial(state, subscribers, token) do
    Minga.Telemetry.span([:minga, :agent, :session_subscribe], %{}, fn ->
      Enum.reduce(subscribers, state, &attach_initial_subscriber(&2, &1, token))
    end)
  end

  @spec attach_initial_subscriber(state(), {pid(), keyword()}, reference() | nil) :: state()
  defp attach_initial_subscriber(state, {pid, opts}, token) when is_pid(pid) do
    if is_reference(token),
      do: send(pid, {:agent_event, self(), {:session_start_attached, token}})

    role = Keyword.get(opts, :role, SubscriberLifecycle.default_role(state.subscriber_lifecycle))

    case reply_to_subscribe(state, pid, role, Keyword.get(opts, :questions?, false) == true) do
      {:reply, {:ok, _attachment}, subscribed} -> subscribed
      {:reply, {:error, _reason}, unchanged} -> unchanged
    end
  end

  @spec reply_to_subscribe(state(), pid(), term(), boolean() | :remote) ::
          {:reply, {:ok, broker_attachment()} | {:error, :invalid_role}, state()}
  defp reply_to_subscribe(state, pid, role, questions?) do
    case SubscriberLifecycle.prepare_subscribe(state.subscriber_lifecycle, pid, role) do
      {:monitor, preparation} ->
        monitor_subscriber(state, pid, preparation, questions?)

      {:already_attached, lifecycle} ->
        lifecycle = maybe_support_questions(lifecycle, pid, questions?)
        state = %{state | subscriber_lifecycle: lifecycle}
        notify_subscriber_connected(pid, state)
        {:reply, {:ok, :existing}, state}

      {:error, :invalid_role} ->
        {:reply, {:error, :invalid_role}, state}
    end
  end

  @spec monitor_subscriber(
          state(),
          pid(),
          SubscriberLifecycle.subscription_preparation(),
          boolean() | :remote
        ) ::
          {:reply, {:ok, broker_attachment()}, state()}
  defp monitor_subscriber(state, pid, preparation, questions?) do
    monitor_ref = Process.monitor(pid)

    case SubscriberLifecycle.complete_subscribe(
           state.subscriber_lifecycle,
           preparation,
           monitor_ref
         ) do
      {:ok, lifecycle, subscription_change, timer_ref} ->
        cancel_reclaim_timer(timer_ref)
        lifecycle = maybe_support_questions(lifecycle, pid, questions?)

        state =
          state
          |> Map.put(:subscriber_lifecycle, lifecycle)
          |> announce_subscription_change(pid, subscription_change)

        notify_subscriber_connected(pid, state)
        {:reply, {:ok, {:created, pid, monitor_ref}}, state}

      {:error, reason} ->
        Process.demonitor(monitor_ref, [:flush])
        raise "subscriber monitor installation failed: #{inspect(reason)}"
    end
  end

  @spec maybe_support_questions(SubscriberLifecycle.t(), pid(), term()) ::
          SubscriberLifecycle.t()
  defp maybe_support_questions(lifecycle, pid, true) when node(pid) == node(),
    do: SubscriberLifecycle.support_questions(lifecycle, pid)

  defp maybe_support_questions(lifecycle, pid, :remote) do
    {receipt, lifecycle} =
      SubscriberLifecycle.remote_question_access(lifecycle, pid, :crypto.strong_rand_bytes(32))

    if is_binary(receipt), do: send(pid, {:agent_question_attachment, self(), receipt})
    lifecycle
  end

  defp maybe_support_questions(lifecycle, _pid, _unsupported), do: lifecycle

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
    send(pid, {:agent_event, self(), {:credentials_status, state.credential_readiness}})
    send(pid, {:agent_event, self(), {:connection_changed, connection_snapshot(state)}})
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
        state = cancel_connection_for_owner(%{state | subscriber_lifecycle: lifecycle}, pid)
        record_user_disconnected(state, pid, attachment.role, reason)
        maybe_schedule_idle_gc(state)

      :unchanged ->
        cancel_connection_for_owner(state, pid)
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
        state = cancel_connection_for_owner(%{state | subscriber_lifecycle: lifecycle}, pid)
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

    candidate = durable_save_candidate(state)

    case save_to_disk(candidate) do
      :ok ->
        {:stop, :normal, candidate}

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

  @spec editor_snapshot_from_state(state()) :: editor_snapshot()
  defp editor_snapshot_from_state(state) do
    %{
      status: TurnExecution.status(state.turn_execution),
      display_status: TurnExecution.display_status(state.turn_execution),
      stop_target: active_turn_target(state),
      pending_approval:
        public_pending_approval(TurnExecution.pending_approval(state.turn_execution), state),
      pending_question: public_question(state.turn_execution),
      queue_target: displayed_queue_target(state),
      error: TurnExecution.error(state.turn_execution),
      active_tool_name: TurnExecution.active_tool_name(state.turn_execution),
      active_tools: TurnExecution.active_tools(state.turn_execution),
      checklist: state.checklist,
      credentials_configured: state.credentials_configured,
      credential_readiness: state.credential_readiness,
      model_selection: state.model_selection,
      connection: connection_snapshot(state)
    }
  end

  @spec editor_arrival_transcript(
          Transcript.t(),
          [FileChange.t()],
          :snapshot | Transcript.Cursor.t()
        ) :: editor_arrival_transcript()
  defp editor_arrival_transcript(transcript, files, cursor) do
    case Transcript.since(transcript, cursor) do
      {:unchanged, cursor} ->
        {:unchanged, cursor}

      {:changes, %Transcript.Changes{entries: [], pin_changes: [], cursor: cursor}} ->
        {:unchanged, cursor}

      {:changes, %Transcript.Changes{} = changes} ->
        {:changes, changes}

      {:snapshot, snapshot} ->
        {:replace, :changed, snapshot, FileChange.changed_file_counts(files)}

      {:reset, _reason, snapshot} ->
        {:replace, :reset, snapshot, FileChange.changed_file_counts(files)}

      {:error, :invalid_cursor} ->
        {:snapshot, snapshot} = Transcript.since(transcript, :snapshot)
        {:replace, :reset, snapshot, nil}
    end
  end

  @spec driver_allowed?(state(), pid()) :: boolean()
  defp driver_allowed?(state, pid),
    do: SubscriberLifecycle.driver?(state.subscriber_lifecycle, pid)

  # ── Broadcasting ────────────────────────────────────────────────────────────

  # Connection setup is serialized here, immediately around the existing
  # credential writers. Network acquisition never runs in this process.
  @spec connection_target(state()) :: ConnectionTarget.t()
  defp connection_target(state) do
    ConnectionTarget.new(self(), state.session_id, state.model_selection, state.connection.epoch)
  end

  @spec connection_snapshot(state()) :: ConnectionSnapshot.t()
  defp connection_snapshot(state) do
    ConnectionSnapshot.new(
      connection_target(state),
      state.credential_readiness,
      state.model_selection,
      state.provider,
      Connection.activity(state.connection),
      Connection.problem(state.connection)
    )
    |> ConnectionSnapshot.project_conversation(state.connection.conversation)
    |> ConnectionSnapshot.project_draft_persistence(Persistence.enabled?(state.persistence))
  end

  @spec validate_connection_target(state(), ConnectionTarget.t()) :: :ok | {:error, :stale_target}
  defp validate_connection_target(state, target) do
    case connection_target(state) do
      ^target -> :ok
      _current -> {:error, :stale_target}
    end
  end

  @spec validate_connection_method(term()) :: :ok | {:error, :unsupported_method}
  defp validate_connection_method({:api_key, provider}) when is_binary(provider) do
    case Credentials.env_var_for(provider) do
      env_var when is_binary(env_var) -> :ok
      nil -> {:error, :unsupported_method}
    end
  end

  defp validate_connection_method(method) when method in [:oauth_browser, :oauth_manual], do: :ok

  defp validate_connection_method(_method), do: {:error, :unsupported_method}

  @spec begin_connection_workflow(
          state(),
          ConnectionTarget.t(),
          Connection.method(),
          pid(),
          {pid(), term()} | nil
        ) ::
          {:reply, term(), state()}
  defp begin_connection_workflow(state, target, method, owner, notify) do
    with :ok <- validate_connection_target(state, target),
         :ok <- validate_connection_owner(state, owner),
         :ok <- validate_connection_notice(state, owner, notify),
         :ok <- validate_connection_method(method) do
      retire_connection_dependencies(state.connection, :cancel)
      owner_ref = Process.monitor(owner)

      {:ok, connection, ref} =
        Connection.begin(state.connection, target, method, {owner, owner_ref}, notify)

      state = publish_connection(%{state | connection: connection})
      notify_connection_input(notify, target, ref, method)
      {:reply, {:ok, ref}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @spec validate_connection_notice(state(), pid(), Connection.notification()) ::
          :ok | {:error, :not_driver}
  defp validate_connection_notice(state, owner, nil) do
    case SubscriberLifecycle.driver(state.subscriber_lifecycle) do
      driver when driver in [nil, owner] -> :ok
      _not_owner -> {:error, :not_driver}
    end
  end

  defp validate_connection_notice(state, _owner, {subscriber, _correlation}) do
    case SubscriberLifecycle.role(state.subscriber_lifecycle, subscriber) do
      :driver when node(subscriber) == node() -> :ok
      _not_driver -> {:error, :not_driver}
    end
  end

  @spec notify_connection_input(
          {pid(), term()} | nil,
          ConnectionTarget.t(),
          reference(),
          Connection.method()
        ) :: :ok
  defp notify_connection_input(nil, _target, _ref, _method), do: :ok

  defp notify_connection_input({subscriber, correlation}, target, ref, method) do
    send(
      subscriber,
      {:agent_event, self(), {:connection_input_requested, correlation, target, ref, method}}
    )

    :ok
  end

  @spec validate_connection_owner(state(), pid()) :: :ok | {:error, :not_driver}
  defp validate_connection_owner(state, owner) when node(owner) == node() do
    case SubscriberLifecycle.role(state.subscriber_lifecycle, owner) do
      :viewer -> {:error, :not_driver}
      _local_or_driver -> :ok
    end
  end

  defp validate_connection_owner(_state, _owner), do: {:error, :not_driver}

  @spec authorize_connection_actor(state(), pid(), :owner | :writer) :: :ok | {:error, atom()}
  defp authorize_connection_actor(state, caller, role) do
    {_ref, _target, _method, {{owner, _}, notify}, worker} = Connection.pending(state.connection)

    with :ok <- validate_connection_owner(state, owner),
         :ok <- validate_connection_notice(state, owner, notify) do
      case {role, worker} do
        {:owner, _worker} when caller == owner -> :ok
        {:writer, {^caller, _monitor}} -> :ok
        _unassigned -> {:error, :not_connection_actor}
      end
    end
  end

  @spec register_connection_worker_workflow(
          state(),
          ConnectionTarget.t(),
          reference(),
          pid(),
          pid()
        ) ::
          {:reply, term(), state()}
  defp register_connection_worker_workflow(state, target, ref, worker, caller) do
    with :ok <- Connection.authorize(state.connection, target, ref, connection_target(state)),
         :ok <- authorize_connection_actor(state, caller, :owner),
         :ok <- validate_local_connection_worker(worker) do
      register_connection_worker_monitor(state, worker)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @spec validate_local_connection_worker(pid()) :: :ok | {:error, :not_connection_actor}
  defp validate_local_connection_worker(worker) when node(worker) == node(), do: :ok
  defp validate_local_connection_worker(_worker), do: {:error, :not_connection_actor}

  @spec register_connection_worker_monitor(state(), pid()) :: {:reply, term(), state()}
  defp register_connection_worker_monitor(state, worker) do
    monitor = Process.monitor(worker)

    case Connection.register_worker(state.connection, {worker, monitor}) do
      {:ok, connection} ->
        {:reply, :ok, %{state | connection: connection}}

      {:error, reason} ->
        Process.demonitor(monitor, [:flush])
        {:reply, {:error, reason}, state}
    end
  end

  @spec cancel_connection_workflow(state(), ConnectionTarget.t(), reference(), pid()) ::
          {:reply, term(), state()}
  defp cancel_connection_workflow(state, target, ref, caller) do
    with :ok <- Connection.authorize(state.connection, target, ref, connection_target(state)),
         :ok <- authorize_connection_actor(state, caller, :owner),
         {:cancelled, connection} <- Connection.cancel(state.connection) do
      retire_connection_dependencies(state.connection, :cancel)
      {:reply, :ok, publish_connection(%{state | connection: connection})}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @spec commit_api_key_workflow(
          state(),
          ConnectionTarget.t(),
          reference(),
          String.t(),
          Secret.t(),
          pid()
        ) ::
          {:reply, term(), state()}
  defp commit_api_key_workflow(state, target, ref, provider, secret, caller) do
    with :ok <- Connection.authorize(state.connection, target, ref, connection_target(state)),
         :ok <- authorize_connection_actor(state, caller, :writer),
         :ok <- Connection.match_method(state.connection, {:api_key, provider}) do
      {state, Secret.write_api_key(secret, provider, connection_credential_opts(state))}
      |> finish_connection_writer()
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @spec commit_oauth_workflow(state(), ConnectionTarget.t(), reference(), Secret.t(), pid()) ::
          {:reply, term(), state()}
  defp commit_oauth_workflow(state, target, ref, secret, caller) do
    with :ok <- Connection.authorize(state.connection, target, ref, connection_target(state)),
         :ok <- authorize_connection_actor(state, caller, :writer),
         :ok <- Connection.match_method(state.connection, :oauth) do
      result =
        Secret.write_oauth(secret, connection_oauth_path(state), connection_oauth_account(state))

      {state, result}
      |> finish_connection_writer()
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @spec connection_oauth_account(state()) :: String.t() | nil
  defp connection_oauth_account(%{
         model_selection: %ModelSelection{
           credential: %MingaAgent.ModelSelection.Credential.OAuth{account_id: account}
         }
       }),
       do: account

  defp connection_oauth_account(_state), do: nil

  @spec connection_oauth_path(state()) :: String.t()
  defp connection_oauth_path(%{
         model_selection: %ModelSelection{
           credential: %MingaAgent.ModelSelection.Credential.OAuth{oauth_path: path}
         }
       })
       when is_binary(path),
       do: path

  defp connection_oauth_path(state) do
    state
    |> connection_credential_opts()
    |> Keyword.get_lazy(:oauth_path, &Credentials.oauth_path/0)
  end

  @spec connection_credential_opts(state()) :: keyword()
  defp connection_credential_opts(state),
    do: Keyword.get(state.provider.opts, :credential_opts, [])

  @spec finish_connection_writer({state(), :ok | {:error, atom()}}) :: {:reply, term(), state()}
  defp finish_connection_writer({state, :ok}) do
    {ref, _target, method, {_owner, notify}, _worker} = Connection.pending(state.connection)
    retire_connection_dependencies(state.connection, :committed)
    {:committed, connection} = Connection.committed(state.connection)

    {state, _readiness_result} =
      %{state | connection: connection}
      |> invalidate_model_discovery()
      |> refresh_credentials_state_result()

    state = publish_connection(state)
    snapshot = connection_snapshot(state)
    notify_connection_saved(method, notify, snapshot.target, ref)
    {:reply, {:ok, snapshot}, state}
  end

  defp finish_connection_writer({state, {:error, reason}}) do
    {ref, target, method, {_owner, notify}, _worker} = Connection.pending(state.connection)

    if method in [:oauth_browser, :oauth_manual],
      do: notify_oauth_failure(notify, target, ref, reason)

    retire_connection_dependencies(state.connection, :cancel)
    {:failed, connection} = Connection.failed(state.connection)
    {:reply, {:error, reason}, publish_connection(%{state | connection: connection})}
  end

  @spec fail_oauth_workflow(state(), ConnectionTarget.t(), reference(), atom(), pid()) :: state()
  defp fail_oauth_workflow(state, target, ref, reason, caller) do
    with :ok <- Connection.authorize(state.connection, target, ref, connection_target(state)),
         :ok <- Connection.match_method(state.connection, :oauth),
         true <-
           authorize_connection_actor(state, caller, :writer) == :ok or
             authorize_connection_actor(state, caller, :owner) == :ok do
      {:reply, {:error, ^reason}, state} = finish_connection_writer({state, {:error, reason}})
      state
    else
      _refused -> state
    end
  end

  @spec notify_oauth_failure(Connection.notification(), ConnectionTarget.t(), reference(), atom()) ::
          :ok
  defp notify_oauth_failure(nil, _target, _ref, _reason), do: :ok

  defp notify_oauth_failure({subscriber, correlation}, target, ref, reason) do
    send(
      subscriber,
      {:agent_event, self(), {:oauth_acquisition_failed, correlation, target, ref, reason}}
    )

    :ok
  end

  @spec notify_connection_saved(
          Connection.method(),
          Connection.notification(),
          ConnectionTarget.t(),
          reference()
        ) :: :ok
  defp notify_connection_saved(_method, nil, _target, _ref), do: :ok

  defp notify_connection_saved(method, {subscriber, correlation}, target, ref) do
    event =
      if match?({:api_key, _}, method),
        do: :connection_api_key_saved,
        else: :connection_oauth_saved

    send(
      subscriber,
      {:agent_event, self(), {event, correlation, target, ref}}
    )

    :ok
  end

  @spec retry_connection_workflow(state(), ConnectionTarget.t()) :: {:reply, term(), state()}
  defp retry_connection_workflow(state, target) do
    case validate_connection_target(state, target) do
      :ok -> restart_provider_workflow(state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @spec restart_provider_workflow(state()) :: {:reply, term(), state()}
  defp restart_provider_workflow(state) do
    {:reset, lifecycle, retry_timer} = ProviderLifecycle.reset_retry(state.provider)
    cancel_provider_retry_timer(retry_timer)
    connection = Connection.provider_recovered(state.connection)

    {state, result} =
      %{state | provider: lifecycle, connection: connection}
      |> invalidate_model_discovery()
      |> refresh_credentials_state_result()

    state = publish_connection(state)

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

  @spec retire_connection_dependencies(Connection.t(), :cancel | :committed) :: :ok
  defp retire_connection_dependencies(connection, disposition) do
    case Connection.pending(connection) do
      {ref, target, method, {{owner, owner_monitor}, _notify}, worker} ->
        if disposition == :cancel and method in [:oauth_browser, :oauth_manual] do
          MingaAgent.OAuth.PendingFlow.cancel_operation(ref, {target.session_id, owner})
        end

        Process.demonitor(owner_monitor, [:flush])
        retire_connection_worker(worker, ref, disposition)

      nil ->
        :ok
    end
  end

  @spec cancel_connection_for_owner(state(), pid()) :: state()
  defp cancel_connection_for_owner(state, owner) do
    case Connection.pending(state.connection) do
      {_ref, _target, _method, {{pid, _monitor}, notify}, _worker}
      when pid == owner or elem(notify, 0) == owner ->
        {:cancelled, connection} = Connection.cancel(state.connection)
        retire_connection_dependencies(state.connection, :cancel)
        publish_connection(%{state | connection: connection})

      _unrelated_or_retired ->
        state
    end
  end

  @spec retire_connection_worker(Connection.dependency() | nil, reference(), :cancel | :committed) ::
          :ok
  defp retire_connection_worker({worker, monitor}, ref, :cancel) do
    send(worker, {:connection_cancelled, ref})
    Process.demonitor(monitor, [:flush])
    :ok
  end

  defp retire_connection_worker({_worker, monitor}, _ref, :committed) do
    Process.demonitor(monitor, [:flush])
    :ok
  end

  defp retire_connection_worker(nil, _ref, _disposition), do: :ok

  @spec connection_dependency_down(state(), pid(), reference(), term()) :: state()
  defp connection_dependency_down(state, pid, monitor, reason) do
    case Connection.dependency_down(state.connection, {pid, monitor}) do
      {:cancelled, connection} ->
        retire_connection_dependencies(state.connection, :cancel)
        publish_connection(%{state | connection: connection})

      :unrelated ->
        handle_subscriber_down(state, pid, monitor, reason)
    end
  end

  @spec set_model_workflow(state(), ModelResolver.intent(), pid()) :: {:reply, term(), state()}
  defp set_model_workflow(
         %{provider: %{module: MingaAgent.Providers.Native}} = state,
         intent,
         caller
       ) do
    opts = model_resolution_opts(state, require_apple_ready: false)

    case ModelResolver.resolve(intent, opts) do
      {:ok, %ModelSelection{route: %{request_provider: :apple}}} ->
        stage_apple_model_selection(state, intent, caller, opts)

      {:ok, selection} ->
        apply_model_choice(state, selection)

      {:error, reason} ->
        {:reply, {:error, ModelResolver.message(reason)}, state}
    end
  end

  defp set_model_workflow(state, _model, _caller) do
    {:reply,
     {:error,
      "Model switching requires the Native provider and a resolved model selection. Use the model picker or /model command."},
     state}
  end

  @spec stage_apple_model_selection(state(), ModelResolver.intent(), pid(), keyword()) ::
          {:reply, term(), state()}
  defp stage_apple_model_selection(state, intent, caller, opts) do
    case model_change_allowed(state) do
      :ok ->
        ref = make_ref()
        probe_opts = Keyword.take(opts, [:apple_availability_fn])
        pending = {ref, caller, connection_target(state), intent}

        {:reply, {:check_apple, ref, node(), probe_opts},
         %{state | apple_selection_probe: pending}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @spec finish_apple_model_selection(
          state(),
          ModelResolver.intent(),
          ModelResolver.apple_availability()
        ) ::
          {:reply, term(), state()}
  defp finish_apple_model_selection(state, _intent, {:error, reason}) do
    {:reply, {:error, ModelResolver.apple_unavailable_message(reason)},
     invalidate_apple_model_discovery(state)}
  end

  defp finish_apple_model_selection(state, intent, {:ok, limit})
       when is_integer(limit) and limit > 0 do
    opts =
      model_resolution_opts(state,
        require_apple_ready: true,
        apple_selection_readiness: {:ok, limit}
      )

    with :ok <- model_change_allowed(state),
         {:ok, %ModelSelection{route: %{request_provider: :apple}} = selection} <-
           ModelResolver.resolve(intent, opts) do
      apply_model_choice(state, selection)
    else
      {:error, reason} when is_atom(reason) -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, ModelResolver.message(reason)}, state}
      {:ok, _other} -> {:reply, {:error, :stale_target}, state}
    end
  end

  @spec apply_model_choice(state(), ModelSelection.t()) ::
          {:reply, :ok | {:error, term()}, state()}
  defp apply_model_choice(state, selection) do
    case ModelSwitch.validate(state.model_selection, selection, state.continuation) do
      {:ok, _compatibility} ->
        case apply_resolved_model_selection(state, selection) do
          {:ok, state} -> {:reply, :ok, state}
          {:error, _reason} = error -> {:reply, error, state}
        end

      {:error, :busy} ->
        {:reply, {:error, :request_active}, state}

      {:error, :budget_exceeded} ->
        detail = ModelSwitch.budget_detail(selection, state.continuation)

        message =
          if detail,
            do: ModelSwitch.budget_exceeded_message(detail),
            else: "Conversation history exceeds the destination model's context window."

        {:reply, {:error, message}, state}

      {:error, {:capability_gap, gaps}} ->
        {:reply, {:error, ModelSwitch.capability_gap_message(gaps)}, state}
    end
  end

  @spec invalidate_connection(state(), :conversation | :selection) :: state()
  defp invalidate_connection(state, reason) do
    retire_connection_dependencies(state.connection, :cancel)

    connection =
      case reason do
        :conversation -> Connection.invalidate(state.connection)
        :selection -> Connection.selection_changed(state.connection)
      end

    %{state | connection: connection, apple_selection_probe: nil}
  end

  @spec commit_connection_selection(state(), state()) :: state()
  defp commit_connection_selection(state, previous) do
    state = retain_resolution_problem(state, nil)

    case {state.model_selection, state.provider.model_name} do
      {selection, model}
      when selection == previous.model_selection and
             model == previous.provider.model_name ->
        state

      _changed ->
        invalidate_connection(state, :selection)
    end
  end

  @spec retain_resolution_problem(state(), ModelResolver.resolution_error() | nil) :: state()
  defp retain_resolution_problem(state, reason),
    do: %{state | connection: Connection.resolved(state.connection, reason)}

  @spec retain_connection_error(state(), Event.Error.t()) :: state()
  defp retain_connection_error(state, event),
    do: %{state | connection: Connection.provider_failed(state.connection, event.kind)}

  @spec mark_connection_provider_failed(state()) :: state()
  defp mark_connection_provider_failed(state),
    do: %{state | connection: Connection.provider_failed(state.connection, :provider_error)}

  @spec publish_connection(state()) :: state()
  defp publish_connection(
         %{
           connection: %Connection{
             epoch: epoch,
             published: %ConnectionSnapshot{
               target: %ConnectionTarget{epoch: epoch},
               model_selection: previous_selection
             }
           }
         } = state
       )
       when previous_selection != state.model_selection do
    # Provider preview/start work can emit existing turn events while a model
    # candidate is staged. Publish its connection only after the model commits
    # and advances the target epoch; rejected candidates never escape.
    state
  end

  defp publish_connection(state) do
    if connection_projection_current?(state, state.connection.published) do
      state
    else
      snapshot = connection_snapshot(state)

      Enum.each(SubscriberLifecycle.subscribers(state.subscriber_lifecycle), fn subscriber ->
        send(subscriber, {:agent_event, self(), {:connection_changed, snapshot}})
      end)

      %{state | connection: Connection.published(state.connection, snapshot)}
    end
  end

  @spec connection_projection_current?(state(), ConnectionSnapshot.t() | nil) :: boolean()
  defp connection_projection_current?(state, %ConnectionSnapshot{} = snapshot) do
    snapshot.target.session == self() and
      snapshot.target.session_id == state.session_id and
      snapshot.target.epoch == state.connection.epoch and
      snapshot.model_selection == state.model_selection and
      snapshot.credential_readiness == state.credential_readiness and
      snapshot.provider_phase == ProviderLifecycle.phase(state.provider) and
      snapshot.operation == Connection.activity(state.connection) and
      snapshot.problem == Connection.problem(state.connection)
  end

  defp connection_projection_current?(_state, nil), do: false

  @spec broadcast(state(), term()) :: state()
  defp broadcast(state, event) do
    state = publish_connection(state)
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

  defp event_log_entry({:tool_started, _tool_call_id, _name, _args}), do: nil

  defp event_log_entry({:tool_update, tool_call_id, name, partial_result}),
    do:
      {:tool_call_updated,
       %{tool_call_id: tool_call_id, name: name, partial_result: partial_result}}

  defp event_log_entry({:tool_ended, %Event.ToolEnd{}}), do: nil

  defp event_log_entry(
         {:file_changed, _session_id, path, before_content, after_content, tool_call_id,
          tool_name}
       ),
       do:
         {:file_edit_proposed,
          EventLog.FileEditPayload.new(
            path,
            before_content,
            after_content,
            tool_call_id,
            tool_name
          )}

  defp event_log_entry({:approval_pending, %PublicApproval{target: target} = approval}) do
    {:approval_requested,
     %{
       approval_id: target.tool_call_id,
       tool_call_id: target.tool_call_id,
       session_id: target.session_id,
       request_id: target.request_id,
       name: approval.name,
       args: approval.args,
       preview: approval.preview
     }}
  end

  defp event_log_entry({:question_requested, %QuestionTarget{} = target, _question}),
    do: {:question_requested, Map.from_struct(target)}

  defp event_log_entry({event, %QuestionTarget{} = target})
       when event in [:question_answered, :question_cancelled, :question_interrupted],
       do: {event, Map.from_struct(target)}

  defp event_log_entry({:todo_plan_updated, todos}),
    do: {:todo_plan_updated, %{todos: todo_items_payload(todos)}}

  defp event_log_entry({:approval_resolved, _target, _decision}), do: nil

  defp event_log_entry({:system_message, _message, _level}), do: nil

  defp event_log_entry({:status_changed, :idle}), do: {:waiting_for_input, %{status: :idle}}
  defp event_log_entry({:status_changed, status}), do: {:status_changed, %{status: status}}

  defp event_log_entry({:prompt_queued, content, queue}),
    do: {:prompt_queued, %{content: content, queue: queue}}

  defp event_log_entry(:messages_changed), do: nil
  defp event_log_entry({:error, message}), do: {:error, %{message: message}}

  defp event_log_entry(
         {:context_usage, estimated_tokens, context_limit, reported_tokens, method}
       ),
       do:
         {:context_usage,
          %{
            estimated_tokens: estimated_tokens,
            context_limit: context_limit,
            reported_tokens: reported_tokens,
            estimation_method: method
          }}

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
    |> put_todo_detail("note", todo_value(todo, :note))
    |> put_todo_detail("result_ref", OutputCodec.encode_reference(todo_value(todo, :result_ref)))
  end

  @spec put_todo_detail(map(), String.t(), term()) :: map()
  defp put_todo_detail(payload, _key, nil), do: payload
  defp put_todo_detail(payload, key, value), do: Map.put(payload, key, value)

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

  @spec begin_provider_request(
          state(),
          String.t() | [ReqLLM.Message.ContentPart.t()]
        ) :: {:ok, Request.t(), state()} | {:error, term(), state()}
  defp begin_provider_request(state, content) do
    case prepare_provider_request(state) do
      {:ok, prepared} -> admit_provider_request(prepared, prepared, content)
      {:error, reason} -> {:error, reason, state}
    end
  end

  @spec prepare_provider_request(state()) :: {:ok, state()} | {:error, term()}
  defp prepare_provider_request(state) do
    with {:ok, prepared, _result} <- refresh_continuation_prefix(state, :current) do
      compact_request_continuation(prepared)
    end
  end

  @spec admit_provider_request(
          state(),
          state(),
          String.t() | [ReqLLM.Message.ContentPart.t()],
          draft_admission()
        ) :: {:ok, Request.t(), state()} | {:error, term(), state()}
  defp admit_provider_request(previous, candidate, content, draft_revision \\ :preserve) do
    with {:ok, turn_id} <- request_turn_id(candidate),
         {:ok, request, continuation} <-
           Continuation.begin_request(candidate.continuation, new_request_id(), turn_id, content) do
      commit_admitted_request(previous, candidate, request, continuation, draft_revision)
    else
      {:error, reason} -> {:error, reason, previous}
    end
  end

  # The turn id is the job-notice display entry, so a boundary recorded for this request never
  # points before an earlier boundary.
  @spec admit_host_request(state(), state(), ReqLLM.Message.t(), pos_integer()) ::
          {:ok, Request.t(), state()} | {:error, term(), state()}
  defp admit_host_request(previous, candidate, notice, turn_id) do
    case Continuation.begin_host_request(
           candidate.continuation,
           new_request_id(),
           turn_id,
           notice
         ) do
      {:ok, request, continuation} ->
        commit_admitted_request(previous, candidate, request, continuation, :preserve)

      {:error, reason} ->
        {:error, reason, previous}
    end
  end

  @spec new_request_id() :: String.t()
  defp new_request_id, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  @spec commit_admitted_request(
          state(),
          state(),
          Request.t(),
          Continuation.t(),
          draft_admission()
        ) ::
          {:ok, Request.t(), state()} | {:error, term(), state()}
  defp commit_admitted_request(previous, candidate, request, continuation, draft_revision) do
    candidate = %{candidate | continuation: continuation}

    {persisted, save_result} =
      if Persistence.enabled?(candidate.persistence) do
        durable = %{candidate | continuation: Continuation.mark_durable(continuation)}
        persist_boundary_candidate(previous, durable, draft_revision)
      else
        {candidate, :ok}
      end

    case save_result do
      :ok ->
        {:ok, request, persisted}

      {:error, reason} ->
        {:error, {:conversation_persistence_failed, reason}, persisted}
    end
  end

  @spec request_turn_id(state()) :: {:ok, pos_integer()}
  defp request_turn_id(state) do
    id =
      state.transcript
      |> Transcript.messages_with_ids()
      |> Enum.reverse()
      |> Enum.find_value(fn
        {message_id, {:user, _text}} -> message_id
        {message_id, {:user, _text, _attachments}} -> message_id
        _other -> nil
      end)

    case id do
      message_id when is_integer(message_id) -> {:ok, message_id}
      nil -> {:ok, state.transcript.next_id}
    end
  end

  @spec compact_request_continuation(state()) :: {:ok, state()} | {:error, term()}
  defp compact_request_continuation(%{continuation: %Continuation{tool_checkpoint: %{}}} = state),
    do: {:ok, state}

  # Apple checks the complete request against the actual native token budget.
  # Do not start inference to compact history on the synchronous submission path.
  defp compact_request_continuation(
         %{model_selection: %{route: %{request_provider: :apple}}} = state
       ),
       do: {:ok, state}

  defp compact_request_continuation(state) do
    if function_exported?(state.provider.module, :compact, 3) do
      result =
        state.provider.module.compact(
          ProviderLifecycle.pid(state.provider),
          state.continuation.messages,
          []
        )

      apply_request_compaction(state, result)
    else
      {:ok, state}
    end
  end

  @spec apply_request_compaction(state(), term()) :: {:ok, state()} | {:error, term()}
  defp apply_request_compaction(state, {:ok, messages, _summary})
       when messages == state.continuation.messages,
       do: {:ok, state}

  defp apply_request_compaction(state, {:ok, messages, summary}) do
    case Continuation.replace_messages(state.continuation, messages) do
      {:ok, continuation} ->
        state = %{state | continuation: continuation}
        {:ok, append_system_message(state, "Context compacted: #{summary}", :info)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_request_compaction(_state, {:error, reason}),
    do: {:error, {:compaction_failed, reason}}

  @spec cancel_provider_request(state()) :: state()
  defp cancel_provider_request(state) do
    %{state | continuation: Continuation.interrupt_request(state.continuation)}
  end

  @spec persist_provider_dispatch_failure(state(), term()) ::
          {:error, term(), state()}
  defp persist_provider_dispatch_failure(request_state, provider_reason) do
    interrupted = cancel_provider_request(request_state)

    case commit_session_transition(request_state, interrupted) do
      {:ok, committed} ->
        {:error, provider_reason, committed}

      {:error, persistence_reason, failed_state} ->
        {:error, {:conversation_persistence_failed, persistence_reason}, failed_state}
    end
  end

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

  @spec measured_start_provider(state()) :: {:ok, pid(), state()} | {:error, term(), state()}
  defp measured_start_provider(state) do
    Minga.Telemetry.span([:minga, :agent, :provider_start], %{}, fn -> start_provider(state) end)
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
    provider_opts =
      case {state.provider.module, state.session_manager} do
        {MingaAgent.Providers.Native, manager} ->
          state.provider.opts
          |> Keyword.put(:session_checklist?, true)
          |> Keyword.put(:session_jobs?, true)
          |> maybe_put_session_manager(manager)

        _provider ->
          state.provider.opts
      end

    case state.provider.module.start_link(provider_opts) do
      {:ok, pid} -> {:ok, pid, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @spec maybe_put_session_manager(keyword(), pid() | nil) :: keyword()
  defp maybe_put_session_manager(opts, manager) when is_pid(manager),
    do: Keyword.put(opts, :session_manager, manager)

  defp maybe_put_session_manager(opts, _manager), do: opts

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
      active_skill_names:
        selected_skill_names(state, provider_active_skill_names(provider_state)),
      project_root: provider_project_root(provider_state, state)
    )
  end

  @spec selected_skill_names(state(), [String.t()]) :: [String.t()]
  defp selected_skill_names(%{provider: %{module: MingaAgent.Providers.Native}} = state, fallback) do
    case PrefixStore.resolve(state.continuation.prefixes, state.continuation.prefixes.selected) do
      %Prefix{skills: skills} -> skills
      :unknown -> fallback
    end
  end

  defp selected_skill_names(_state, fallback), do: fallback

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

  # The hook learns the folder the session was started in, or none. A session without a folder has no root to report.
  @spec session_start_root(state()) :: String.t() | nil
  defp session_start_root(state) do
    opts = state.provider.opts

    case Keyword.get(opts, :working_folder) do
      nil -> Keyword.get(opts, :project_root)
      working_folder -> MingaAgent.WorkingFolder.root(working_folder)
    end
  end

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

  # Credential snapshots perform bounded filesystem and environment work without network I/O.
  @spec refresh_credentials_state(state()) :: state()
  defp refresh_credentials_state(state) do
    {state, _result} = refresh_credentials_state_result(state)
    state
  end

  @spec refresh_credentials_state_result(state()) ::
          {state(), :ok | {:error, term()}}
  defp refresh_credentials_state_result(
         %{provider: %{module: MingaAgent.Providers.Native}} = state
       ) do
    snapshot = state.credentials_snapshot_fn.()
    opts = Keyword.put(model_resolution_opts(state), :credential_snapshot, snapshot)

    result =
      case state.model_selection do
        %ModelSelection{} = selection -> ModelResolver.restore(selection, opts)
        nil -> ModelResolver.resolve(state.provider.model_name, opts)
      end

    case result do
      {:ok, selection} ->
        state =
          state
          |> install_model_selection(selection)
          |> commit_connection_selection(state)

        refresh_credentials_from_snapshot(state, snapshot, true)

      {:error, :no_available_model} ->
        state =
          state
          |> retain_resolution_problem(:no_available_model)
          |> install_credential_readiness(:unconfigured)
          |> broadcast_credential_readiness()

        {state, {:error, ModelResolver.message(:no_available_model)}}

      {:error, reason} ->
        state =
          state
          |> retain_resolution_problem(reason)
          |> install_credential_readiness(:unconfigured)
          |> broadcast_credential_readiness()

        {state, {:error, ModelResolver.message(reason)}}
    end
  end

  defp refresh_credentials_state_result(state) do
    snapshot = state.credentials_snapshot_fn.()

    configured? =
      session_credentials_configured?(
        state.provider.module,
        state.provider.opts,
        snapshot,
        state.credentials_configured_fn
      )

    refresh_credentials_from_snapshot(state, snapshot, configured?)
  end

  @spec refresh_credentials_from_snapshot(state(), CredentialSnapshot.t(), boolean()) ::
          {state(), :ok | {:error, term()}}
  defp refresh_credentials_from_snapshot(state, _snapshot, true) do
    state = install_credential_readiness(state, :configured)
    {state, result} = maybe_start_provider_result(state)
    {state, model_result} = apply_pending_model_change(state)
    {broadcast_credential_readiness(state), first_error(result, model_result)}
  end

  defp refresh_credentials_from_snapshot(state, _snapshot, false) do
    state =
      state
      |> install_credential_readiness(:unconfigured)
      |> broadcast_credential_readiness()

    {state, {:error, :no_available_model}}
  end

  @spec install_credential_readiness(state(), Credentials.readiness()) :: state()
  defp install_credential_readiness(state, readiness) do
    %{
      state
      | credential_readiness: readiness,
        credentials_configured: readiness == :configured
    }
  end

  @spec broadcast_credential_readiness(state()) :: state()
  defp broadcast_credential_readiness(state) do
    broadcast(state, {:credentials_status, state.credential_readiness})
  end

  @spec apply_pending_model_change(state()) :: {state(), :ok | {:error, term()}}
  defp apply_pending_model_change(%{pending_model_change: nil} = state), do: {state, :ok}

  defp apply_pending_model_change(%{pending_model_change: model} = state) do
    state = %{state | pending_model_change: nil}

    case ProviderLifecycle.pid(state.provider) do
      nil ->
        {state, :ok}

      provider ->
        {state, dispatch_optional(state.provider.module, :set_model, [provider, model])}
    end
  end

  @spec first_error(:ok | {:error, term()}, :ok | {:error, term()}) ::
          :ok | {:error, term()}
  defp first_error({:error, _reason} = error, _other), do: error
  defp first_error(:ok, result), do: result

  @spec initial_model_selection(
          ProviderResolver.resolved(),
          String.t(),
          keyword(),
          CredentialSnapshot.t(),
          String.t() | nil
        ) :: {ModelSelection.t() | nil, ModelResolver.resolution_error() | nil}
  defp initial_model_selection(
         %{module: MingaAgent.Providers.Native} = resolution,
         model,
         provider_opts,
         snapshot,
         thinking_level
       ) do
    Minga.Telemetry.span([:minga, :agent, :session_model_resolve], %{}, fn ->
      resolve_initial_model(resolution, model, provider_opts, snapshot, thinking_level)
    end)
  end

  defp initial_model_selection(_resolution, _model, _provider_opts, _snapshot, _thinking),
    do: {nil, nil}

  @spec resolve_initial_model(
          ProviderResolver.resolved(),
          String.t(),
          keyword(),
          CredentialSnapshot.t(),
          String.t() | nil
        ) :: {ModelSelection.t() | nil, ModelResolver.resolution_error() | nil}
  defp resolve_initial_model(resolution, model, provider_opts, snapshot, thinking_level) do
    config = Keyword.get_lazy(provider_opts, :config, &AgentConfig.resolve/0)

    resolver_opts =
      [
        config: config,
        credential_snapshot: snapshot,
        backend_spec: resolution.spec
      ]
      |> Keyword.merge(Keyword.get(provider_opts, :model_resolver_opts, []))

    case ModelResolver.resolve(model, resolver_opts) do
      {:ok, selection} ->
        case maybe_apply_initial_reasoning(selection, thinking_level) do
          {:ok, selection} -> {selection, nil}
          {:error, message} -> {nil, {:incompatible_selection, message}}
        end

      {:error, reason} ->
        {nil, reason}
    end
  end

  @spec maybe_apply_initial_reasoning(ModelSelection.t(), String.t() | nil) ::
          {:ok, ModelSelection.t()} | {:error, String.t()}
  defp maybe_apply_initial_reasoning(selection, nil), do: {:ok, selection}

  defp maybe_apply_initial_reasoning(selection, level),
    do: ModelSelection.with_reasoning(selection, level)

  @spec selection_model_name(ModelSelection.t() | nil, String.t()) :: String.t()
  defp selection_model_name(%ModelSelection{} = selection, _fallback),
    do: ModelSelection.id(selection)

  defp selection_model_name(nil, fallback), do: fallback

  @spec maybe_put_model_selection(keyword(), ModelSelection.t() | nil) :: keyword()
  defp maybe_put_model_selection(opts, nil), do: Keyword.delete(opts, :model_selection)

  defp maybe_put_model_selection(opts, %ModelSelection{} = selection),
    do: opts |> Keyword.delete(:thinking_level) |> Keyword.put(:model_selection, selection)

  @spec invalidate_model_discovery(state()) :: state()
  defp invalidate_model_discovery(state) do
    case state.model_discovery do
      {validity, _codex, _apple} -> :atomics.put(validity, 1, 0)
      nil -> :ok
    end

    %{state | model_discovery: nil, model_discovery_request: nil}
  end

  @spec invalidate_apple_model_discovery(state()) :: state()
  defp invalidate_apple_model_discovery(state) do
    case state.model_discovery do
      {validity, codex, _apple} ->
        :atomics.put(validity, 1, 0)
        %{state | model_discovery: {validity, codex, nil}, model_discovery_request: nil}

      nil ->
        %{state | model_discovery_request: nil}
    end
  end

  @spec local_model_discovery(state(), CredentialSnapshot.t()) ::
          {:ok, [ModelCandidate.t()], :superseded, nil}
  defp local_model_discovery(state, snapshot) do
    candidates = discovered_model_candidates(%{state | model_discovery: nil}, snapshot)
    {:ok, candidates, :superseded, nil}
  end

  @spec model_discovery_notice(
          ModelSelection.Credential.OAuth.t() | nil,
          CodexModels.result(),
          ModelResolver.apple_availability(),
          ModelSelection.t() | nil
        ) :: String.t() | nil
  defp model_discovery_notice(credential, codex, apple, selection) do
    codex_notice =
      case {credential, codex} do
        {%ModelSelection.Credential.OAuth{}, {:error, reason}} -> CodexModels.message(reason)
        _available_or_unconfigured -> nil
      end

    apple_notice = apple_discovery_notice(apple, selection)

    case Enum.reject([codex_notice, apple_notice], &is_nil/1) do
      [] -> nil
      notices -> Enum.join(notices, " ")
    end
  end

  @spec apple_discovery_notice(ModelResolver.apple_availability(), ModelSelection.t() | nil) ::
          String.t() | nil
  defp apple_discovery_notice({:ok, _context}, _selection), do: nil

  defp apple_discovery_notice({:error, reason}, %ModelSelection{
         route: %{request_provider: :apple}
       }),
       do: ModelResolver.apple_unavailable_message(reason)

  defp apple_discovery_notice({:error, reason}, _selection)
       when reason in [:unsupported, :helper_missing],
       do: nil

  defp apple_discovery_notice({:error, reason}, _selection),
    do: ModelResolver.apple_unavailable_message(reason)

  @spec discovered_model_candidates(state(), CredentialSnapshot.t(), boolean()) ::
          [ModelCandidate.t()]
  defp discovered_model_candidates(state, snapshot, include_apple? \\ true) do
    {codex, apple} =
      case state.model_discovery do
        {_ref, codex, apple} -> {codex, apple}
        nil -> {{:error, :not_loaded}, nil}
      end

    candidates =
      ModelResolver.candidates(
        model_resolution_opts(state,
          current: state.model_selection,
          credential_snapshot: snapshot,
          apple_discovery: if(include_apple?, do: apple),
          codex_models: codex
        )
      )

    state
    |> observed_usage_limits()
    |> UsageLimits.annotate(candidates, DateTime.utc_now())
  end

  # The limits every session observed on catalog routes. Without the registry, no limit is known.
  @spec observed_usage_limits(state()) :: UsageLimits.t()
  defp observed_usage_limits(state) do
    InferenceRouteRegistry.usage_limits(route_registry(state))
  catch
    :exit, _reason -> UsageLimits.new()
  end

  @spec route_registry(state()) :: GenServer.server()
  defp route_registry(state) do
    state.provider.opts
    |> Keyword.get(:model_resolver_opts, [])
    |> inference_route_registry()
  end

  @spec model_resolution_opts(state(), keyword()) :: keyword()
  defp model_resolution_opts(state, extra \\ []) do
    state.provider.opts
    |> Keyword.get(:model_resolver_opts, [])
    |> Keyword.merge(extra)
    |> Keyword.put_new_lazy(:config, fn ->
      Keyword.get_lazy(state.provider.opts, :config, &AgentConfig.resolve/0)
    end)
    |> Keyword.put_new_lazy(:credential_snapshot, state.credentials_snapshot_fn)
  end

  @spec model_change_allowed(state()) :: :ok | {:error, atom()}
  defp model_change_allowed(%{continuation: %{active_request: %Request{}}}),
    do: {:error, :request_active}

  defp model_change_allowed(%{continuation: %{tool_checkpoint: %{}}}),
    do: {:error, :effect_reconciliation_required}

  defp model_change_allowed(%{continuation: %{dispatch: {_owner, _dispatch}}}),
    do: {:error, :dispatch_active}

  defp model_change_allowed(_state), do: :ok

  @spec apply_resolved_model_selection(state(), ModelSelection.t()) ::
          {:ok, state()} | {:error, term()}
  defp apply_resolved_model_selection(state, selection) do
    with :ok <- model_change_allowed(state), do: apply_allowed_model_selection(state, selection)
  end

  @spec apply_allowed_model_selection(state(), ModelSelection.t()) ::
          {:ok, state()} | {:error, term()}
  defp apply_allowed_model_selection(%{provider: provider} = state, selection)
       when ProviderLifecycle.is_detached(provider) do
    prepared =
      state |> install_model_selection(selection) |> install_credential_readiness(:configured)

    case start_loaded_provider(prepared) do
      {:ok, staged} ->
        case commit_model_selection(staged, state, selection) do
          {:ok, committed} ->
            {:ok, finish_loaded_provider_attachment(committed, state.provider)}

          {:error, _reason} = error ->
            stop_provider_lifecycle(staged)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_allowed_model_selection(state, selection) do
    commit_model_selection(state, state, selection)
  end

  @spec commit_model_selection(state(), state(), ModelSelection.t()) ::
          {:ok, state()} | {:error, term()}
  defp commit_model_selection(state, previous, selection) do
    operation = {:model, selection, model_transition(previous.model_selection, selection)}

    with {:ok, committed, :ok} <- refresh_continuation_prefix(state, operation) do
      {:ok,
       committed
       |> commit_connection_selection(previous)
       |> install_credential_readiness(:configured)
       |> broadcast_credential_readiness()
       |> publish_connection()}
    end
  end

  @spec model_transition(ModelSelection.t() | nil, ModelSelection.t()) ::
          :exact | {:handoff, :retain | :reject}
  defp model_transition(%ModelSelection{route: route}, %ModelSelection{route: route}), do: :exact

  defp model_transition(
         %ModelSelection{
           route: %{request_provider: provider, execution: %{base_url: endpoint}},
           credential: credential
         },
         %ModelSelection{
           route: %{request_provider: provider, execution: %{base_url: endpoint}},
           credential: credential
         }
       ),
       do: {:handoff, :retain}

  defp model_transition(_previous, _selection), do: {:handoff, :reject}

  @spec install_model_selection(state(), ModelSelection.t()) :: state()
  defp install_model_selection(state, selection) do
    stable_id = ModelSelection.id(selection)
    provider_name = selection.route.model_provider

    provider_opts =
      state.provider.opts
      |> Keyword.put(:model, stable_id)
      |> Keyword.put(:provider, provider_name)
      |> maybe_put_model_selection(selection)

    lifecycle =
      ProviderLifecycle.replace(
        state.provider,
        stable_id,
        provider_name,
        provider_opts
      )

    %{
      state
      | provider: lifecycle,
        model_selection: selection,
        unresolved_route: nil,
        credentials_configured: true
    }
  end

  @spec next_model_candidate([ModelCandidate.t()]) :: ModelCandidate.t() | nil
  defp next_model_candidate([]), do: nil

  defp next_model_candidate([first | _rest] = candidates) do
    case Enum.find_index(candidates, & &1.current) do
      nil -> first
      index -> Enum.at(candidates, index + 1, first)
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

  # The editor passes an empty provider while no model is selected. A saved record requires a
  # provider name, so a blank one falls back to the same "unknown" name as an absent one.
  defp session_provider_name(_provider, provider_opts) do
    case provider_opts |> Keyword.get(:provider) |> to_string() do
      "" -> "unknown"
      provider -> provider
    end
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
      {:start, lifecycle, retry_timer} = ProviderLifecycle.start(lifecycle)
      cancel_provider_retry_timer(retry_timer)
      state = %{state | provider: lifecycle}

      case measured_start_provider(state) do
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
    state |> attach_provider_process(pid) |> finish_provider_attachment()
  end

  @spec attach_provider_process(state(), pid()) :: state()
  defp attach_provider_process(state, pid) do
    Process.unlink(pid)
    monitor_ref = Process.monitor(pid)
    {:ok, lifecycle} = ProviderLifecycle.attach(state.provider, pid, monitor_ref)

    %{state | provider: lifecycle}
  end

  @spec finish_provider_attachment(state()) :: state()
  defp finish_provider_attachment(state) do
    if is_pid(state.session_manager) do
      send(
        state.session_manager,
        {:session_provider_attached, state.session_id, self(),
         ProviderLifecycle.pid(state.provider)}
      )
    end

    state = clear_provider_start_error(state)
    state = %{state | connection: Connection.provider_recovered(state.connection)}

    state = apply_pending_thinking_level(state)
    state = maybe_show_auth_onboarding(state)
    dispatch_session_start(state)
    publish_connection(state)
  end

  @spec clear_provider_start_error(state()) :: state()
  defp clear_provider_start_error(state) do
    case TurnExecution.recover(state.turn_execution) do
      {:changed, execution} ->
        state = announce_display_status(state, execution)
        %{state | turn_execution: execution}

      :unchanged ->
        state
    end
  end

  @spec report_provider_start_error(state(), term()) :: state()
  defp report_provider_start_error(state, reason) do
    Minga.Log.error(:agent, "[Agent.Session] failed to start provider: #{inspect(reason)}")
    {:failed, lifecycle, lease} = ProviderLifecycle.failure(state.provider, reason)
    release_provider_lease(lease)

    state = %{
      state
      | provider: lifecycle,
        connection: Connection.provider_failed(state.connection, :startup_failed)
    }

    mark_provider_failed(state, format_error(reason))
  end

  @spec handle_provider_death(state(), term()) :: state()
  defp handle_provider_death(state, reason) do
    Minga.Log.warning(:agent, "[Agent.Session] provider process died: #{inspect(reason)}")
    {:failed, lifecycle, lease} = ProviderLifecycle.failure(state.provider, reason)
    release_provider_lease(lease)

    state =
      state
      |> Map.put(:provider, lifecycle)
      |> mark_connection_provider_failed()
      |> mark_provider_failed("Agent provider crashed")
      |> recover_interrupted_request()

    state = maybe_schedule_provider_restart(state, reason)
    broadcast(state, {:error, TurnExecution.error(state.turn_execution)})
    state
  end

  @spec recover_interrupted_request(state()) :: state()
  defp recover_interrupted_request(state) do
    previous_continuation = state.continuation
    continuation = Continuation.interrupt_request(previous_continuation)
    state = %{state | continuation: continuation}

    case {continuation.tool_checkpoint, continuation == previous_continuation} do
      {nil, true} ->
        state

      {nil, false} ->
        {persisted, _save_result} = persist_completed_boundary(state)
        persisted

      {_checkpoint, _changed?} ->
        reconcile_interrupted_checkpoint(state)
    end
  end

  @spec maybe_schedule_provider_restart(state(), term()) :: state()
  defp maybe_schedule_provider_restart(state, reason) do
    case ProviderLifecycle.retry(
           state.provider,
           reason,
           System.monotonic_time(:millisecond)
         ) do
      {:retry, lifecycle, delay_ms} ->
        state = %{state | provider: lifecycle}
        token = make_ref()
        timer_ref = Process.send_after(self(), {:start_provider, token}, delay_ms)
        {:ok, lifecycle} = ProviderLifecycle.install_retry_timer(state.provider, timer_ref, token)

        %{state | provider: lifecycle}
        |> put_provider_retrying_error(delay_ms)

      {:terminal_failure, lifecycle} ->
        state
        |> Map.put(:provider, lifecycle)
        |> put_provider_restart_exhausted_error()
    end
  end

  @spec await_provider_stop(pid(), reference()) :: :ok
  defp await_provider_stop(pid, monitor_ref) do
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

  @spec cancel_provider_retry_timer(ProviderLifecycle.retry_timer() | nil) :: :ok
  defp cancel_provider_retry_timer(nil), do: :ok

  defp cancel_provider_retry_timer({timer_ref, _token}) do
    _cancelled? = Process.cancel_timer(timer_ref)
    :ok
  end

  @spec stop_provider_lifecycle(state()) :: state()
  defp stop_provider_lifecycle(state) do
    case ProviderLifecycle.stop(state.provider) do
      {:stop_provider, lifecycle, pid, monitor_ref, lease} ->
        await_provider_stop(pid, monitor_ref)
        release_provider_lease(lease)
        %{state | provider: lifecycle}

      {:stop_detached, lifecycle, lease, retry_timer} ->
        cancel_provider_retry_timer(retry_timer)
        release_provider_lease(lease)
        %{state | provider: lifecycle}
    end
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

    Open a masked API key prompt for your provider:

      /auth anthropic           Anthropic Claude
      /auth openai              OpenAI GPT
      /auth google              Google Gemini
      /auth openrouter          OpenRouter (many models)
      /auth groq                Groq
      /auth deepseek            DeepSeek

    Or sign in with a ChatGPT subscription (OpenAI accounts only):

      /login                    Sign in via browser, no key needed
      /login --manual           Sign in by pasting a browser redirect

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

  # A contributed route already turned its failure into one actionable sentence.
  defp humanize_error(%Event.Error{kind: kind, message: message}, %{
         model_selection: %ModelSelection{route: %{request_provider: :contributed}}
       })
       when kind != :context_transition_required and is_binary(message) and message != "",
       do: message

  defp humanize_error(%Event.Error{kind: kind, message: message, provider: provider}, state) do
    humanize_error_kind(kind, message, provider || provider_slug(state))
  end

  @spec humanize_error_kind(Event.Error.kind(), String.t(), String.t()) :: String.t()
  defp humanize_error_kind(:auth_failed, _message, provider),
    do: "Couldn't authenticate with #{provider_label(provider)}. #{auth_hint(provider)}"

  defp humanize_error_kind(:rate_limited, _message, _provider),
    do: "The model provider is rate limiting requests. Wait a moment, then try again."

  # The provider already named the plan and its local reset time.
  defp humanize_error_kind(:usage_limit_reached, message, _provider), do: message

  defp humanize_error_kind(:unreachable, _message, _provider),
    do: "Couldn't reach the model provider. Check your network connection, then try again."

  defp humanize_error_kind(:invalid_model, message, _provider), do: message

  defp humanize_error_kind(:context_transition_required, _message, _provider),
    do: Event.Error.context_transition_message()

  defp humanize_error_kind(:provider_error, message, "apple"), do: message
  defp humanize_error_kind(:request_admission_refused, message, _provider), do: message

  defp humanize_error_kind(:provider_error, _message, _provider) do
    "The model provider returned an unexpected error. Open Messages for details, or pick another configured model with /model."
  end

  defp humanize_error_kind(:tool_error, message, _provider), do: message

  defp humanize_error_kind(:internal_error, _message, _provider) do
    "The model provider returned an unexpected error. Open Messages for details, or pick another configured model with /model."
  end

  @type legacy_error_kind ::
          :auth_failed
          | :usage_limit_reached
          | :rate_limited
          | :unreachable
          | :raw_dump
          | :passthrough

  @spec humanize_legacy_error(String.t(), String.t()) :: String.t()
  defp humanize_legacy_error(message, provider) when is_binary(message) do
    humanize_legacy_error_kind(classify_legacy_error(message), message, provider)
  end

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
      {:usage_limit_reached, UsageLimit.message_signal?(message)},
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

  # Text carries no reset time, so none is named.
  defp humanize_legacy_error_kind(:usage_limit_reached, _message, _provider),
    do: "Your plan's usage limit is reached. Choose another model with /model to continue now."

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
    do: "Run /auth #{provider} to enter a key, or pick another configured model with /model."

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
  @spec initial_credentials_configured?(
          module(),
          ModelSelection.t() | nil,
          keyword(),
          CredentialSnapshot.t(),
          credentials_configured_fn() | nil
        ) :: boolean()
  defp initial_credentials_configured?(
         MingaAgent.Providers.Native,
         %ModelSelection{},
         _opts,
         _snapshot,
         _configured_fn
       ),
       do: true

  defp initial_credentials_configured?(
         MingaAgent.Providers.Native,
         nil,
         _opts,
         _snapshot,
         _configured_fn
       ),
       do: false

  defp initial_credentials_configured?(module, _selection, opts, snapshot, configured_fn),
    do: session_credentials_configured?(module, opts, snapshot, configured_fn)

  @spec session_credentials_configured?(
          module(),
          keyword(),
          CredentialSnapshot.t(),
          credentials_configured_fn() | nil
        ) :: boolean()
  defp session_credentials_configured?(
         provider_module,
         provider_opts,
         snapshot,
         credentials_configured_fn
       ) do
    provider_module != MingaAgent.Providers.Native or
      Keyword.has_key?(provider_opts, :llm_client) or
      configured_override?(credentials_configured_fn, snapshot)
  end

  @spec configured_override?(credentials_configured_fn() | nil, CredentialSnapshot.t()) ::
          boolean()
  defp configured_override?(configured_fn, _snapshot) when is_function(configured_fn, 0),
    do: configured_fn.()

  defp configured_override?(nil, snapshot), do: Credentials.any_configured?(snapshot)

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

  @spec refresh_continuation_prefix(state(), term()) ::
          {:ok, state(), term()} | {:error, term()}
  defp refresh_continuation_prefix(
         %{continuation: %Continuation{active_request: %Request{}}},
         _operation
       ),
       do: {:error, :request_active}

  defp refresh_continuation_prefix(
         %{continuation: %Continuation{tool_checkpoint: %{}}},
         _operation
       ),
       do: {:error, :effect_reconciliation_required}

  defp refresh_continuation_prefix(
         %{provider: %{module: MingaAgent.Providers.Native}} = state,
         operation
       ) do
    provider_pid = ProviderLifecycle.pid(state.provider)

    selected =
      PrefixStore.resolve(state.continuation.prefixes, state.continuation.prefixes.selected)

    preview_operation =
      case selected do
        %Prefix{skills: skills} -> {:selected, operation, skills}
        :unknown -> operation
      end

    preview_operation =
      if question_schema_enabled?(state, selected, operation),
        do: {:with_questions, preview_operation},
        else: preview_operation

    case preview_native_prefix(provider_pid, preview_operation) do
      {:ok, candidate, token, result} ->
        commit_native_prefix_preview(state, operation, candidate, token, result)

      {:error, _reason} = error ->
        error
    end
  end

  defp refresh_continuation_prefix(state, :current) do
    case state.provider.module.get_state(ProviderLifecycle.pid(state.provider)) do
      {:ok, %{system_prompt: prompt}} when is_binary(prompt) ->
        identity = %{native_contract: :provider_owned, provider: state.provider.module}

        with {:ok, candidate} <- PrefixStore.candidate(prompt, [], identity),
             {:ok, status, continuation} <-
               Continuation.change_prefix(state.continuation, candidate),
             {:ok, committed} <-
               commit_prefix_transition(state, %{state | continuation: continuation}, status) do
          {:ok, announce_prefix_transition(committed, status), :ok}
        end

      _provider_owned ->
        {:ok, state, :ok}
    end
  end

  defp refresh_continuation_prefix(_state, _operation),
    do: {:error, :provider_prefix_transition_unavailable}

  @spec question_schema_enabled?(state(), Prefix.t() | :unknown, term()) :: boolean()
  defp question_schema_enabled?(state, _selected, {:model, _selection, {:handoff, _policy}}),
    do: SubscriberLifecycle.driver_supports_questions?(state.subscriber_lifecycle)

  defp question_schema_enabled?(
         %{continuation: %Continuation{boundaries: [], messages: []}} = state,
         _selected,
         _operation
       ),
       do: SubscriberLifecycle.driver_supports_questions?(state.subscriber_lifecycle)

  defp question_schema_enabled?(
         %{
           continuation: %Continuation{boundaries: [], messages: [%ReqLLM.Message{role: :system}]}
         } =
           state,
         _selected,
         _operation
       ),
       do: SubscriberLifecycle.driver_supports_questions?(state.subscriber_lifecycle)

  defp question_schema_enabled?(_state, %Prefix{schemas: schemas}, _operation),
    do: Enum.any?(schemas, &(&1.name == "ask_user"))

  defp question_schema_enabled?(_state, :unknown, _operation), do: false

  @spec preview_native_prefix(pid(), term()) :: term()
  defp preview_native_prefix(provider, operation) do
    token = make_ref()

    try do
      GenServer.call(provider, {:preview_prefix, token, operation})
    catch
      :exit, reason ->
        discard_native_prefix_preview(provider, token)
        {:error, {:provider_unavailable, reason}}
    end
  end

  @spec validate_native_prefix_preview(pid(), reference(), [ReqLLM.Message.t()]) ::
          :ok | {:error, term()}
  defp validate_native_prefix_preview(provider, token, messages) do
    GenServer.call(provider, {:validate_prefix_preview, token, messages})
  catch
    :exit, reason -> {:error, {:provider_unavailable, reason}}
  end

  @spec discard_native_prefix_preview(pid(), reference()) :: :ok
  defp discard_native_prefix_preview(provider, token) do
    GenServer.cast(provider, {:discard_prefix_preview, token, self()})
  end

  @spec commit_native_prefix_preview(
          state(),
          term(),
          MingaAgent.Session.Prefix.t(),
          reference(),
          term()
        ) ::
          {:ok, state(), term()} | {:error, term()}
  defp commit_native_prefix_preview(state, operation, prefix, token, result) do
    provider = ProviderLifecycle.pid(state.provider)

    with {:ok, status, continuation} <-
           transition_model_prefix(state.continuation, operation, prefix),
         :ok <- validate_native_prefix_preview(provider, token, continuation.messages),
         candidate = prefix_transition_candidate(state, operation, continuation),
         {:ok, committed} <- commit_prefix_transition(state, candidate, status),
         :ok <- GenServer.call(provider, {:commit_prefix_preview, token}) do
      committed =
        committed
        |> announce_prefix_transition(status)
        |> disclose_prefix_omission(status, prefix)

      {:ok, committed, result}
    else
      {:error, _reason} = error ->
        discard_native_prefix_preview(provider, token)
        error
    end
  end

  @spec transition_model_prefix(Continuation.t(), term(), Prefix.t()) ::
          {:ok, :applied | :unchanged, Continuation.t()} | {:error, term()}
  defp transition_model_prefix(
         continuation,
         {:model, _selection, {:handoff, file_policy}},
         prefix
       ) do
    case Continuation.change_prefix(continuation, prefix) do
      {:ok, :unchanged, _continuation} = unchanged ->
        unchanged

      _handoff_required ->
        case Continuation.change_model_prefix(continuation, prefix, file_policy) do
          {:error, reason}
          when reason in [
                 :unportable_attachment,
                 :unportable_compaction,
                 :unportable_content,
                 :incomplete_tool_exchange
               ] ->
            {:error, MingaAgent.Session.PortableHistory.message(reason)}

          result ->
            result
        end
    end
  end

  defp transition_model_prefix(continuation, _operation, prefix),
    do: Continuation.change_prefix(continuation, prefix)

  @spec prefix_transition_candidate(state(), term(), Continuation.t()) :: state()
  defp prefix_transition_candidate(state, {:model, selection, _changed?}, continuation) do
    candidate = install_model_selection(state, selection)
    %{candidate | continuation: continuation}
  end

  defp prefix_transition_candidate(state, _operation, continuation),
    do: %{state | continuation: continuation}

  @spec announce_prefix_transition(state(), :applied | :unchanged) :: state()
  defp announce_prefix_transition(state, :unchanged), do: state

  defp announce_prefix_transition(state, :applied),
    do:
      broadcast(
        state,
        {:prefix_changed, %{epoch_id: state.continuation.prefixes.selected, status: :applied}}
      )

  # A route that leaves instruction parts out of its prefix says so in the transcript.
  @spec disclose_prefix_omission(state(), :applied | :unchanged, Prefix.t()) :: state()
  defp disclose_prefix_omission(
         %{model_selection: %ModelSelection{route: route}} = state,
         :applied,
         %Prefix{} = prefix
       ) do
    case Prefix.omission_notice(prefix, route.display_name) do
      nil -> state
      notice -> state |> append_system_message(notice, :info) |> notify_messages_changed()
    end
  end

  defp disclose_prefix_omission(state, _status, _prefix), do: state

  @spec commit_prefix_transition(state(), state(), :unchanged | :applied) ::
          {:ok, state()} | {:error, term()}
  defp commit_prefix_transition(state, candidate, :unchanged)
       when state.model_selection == candidate.model_selection, do: {:ok, state}

  defp commit_prefix_transition(state, candidate, _status) do
    case commit_effect_snapshot(state, candidate) do
      {:ok, committed} -> {:ok, committed}
      {:error, reason} -> {:error, {:prefix_persistence_failed, reason}}
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

  @spec durable_save_candidate(state()) :: state()
  defp durable_save_candidate(%{continuation: %Continuation{active_request: nil}} = state) do
    %{state | continuation: Continuation.mark_durable(state.continuation)}
  end

  defp durable_save_candidate(state), do: state

  @spec recover_durable_retry(state()) :: {state(), boolean()}
  defp recover_durable_retry(state) do
    case {TurnExecution.error(state.turn_execution), TurnExecution.recover(state.turn_execution)} do
      {"The turn finished in memory but could not be saved. Its result is not yet durable.",
       {:changed, execution}} ->
        candidate =
          state
          |> Map.put(:turn_execution, execution)
          |> append_system_message("The completed turn is now saved and resumable.", :info)

        {candidate, true}

      _other ->
        {state, false}
    end
  end

  @spec maybe_publish_resumable_boundary(state(), non_neg_integer()) :: state()
  defp maybe_publish_resumable_boundary(state, previous_durable_revision) do
    if state.continuation.durable_revision > previous_durable_revision do
      broadcast(state, {:resumable_boundary, state.continuation.durable_revision})
    else
      state
    end
  end

  @spec commit_effect_snapshot(state(), state(), snapshot_write_mode()) ::
          {:ok, state()} | {:error, term()}
  defp commit_effect_snapshot(state, candidate, mode \\ :preserve) do
    if Persistence.enabled?(state.persistence) do
      candidate = %{candidate | continuation: Continuation.mark_durable(candidate.continuation)}

      mode = snapshot_write_mode(state, candidate, mode)

      case save_to_disk(candidate, mode) do
        :ok ->
          {persistence, timer_to_cancel} = Persistence.cancel(candidate.persistence)
          cancel_runtime_timer(timer_to_cancel)
          {:ok, %{candidate | persistence: Persistence.saved(persistence)}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      # Non-persistent sessions keep the checkpoint in Session memory. They
      # cannot be restored after a process restart, so no durable guarantee is
      # claimed for their effects.
      {:ok, candidate}
    end
  end

  @typep snapshot_write_mode ::
           draft_admission()
           | :queue_transition
           | {:queued_draft, non_neg_integer()}
           | {:recalled_draft, non_neg_integer(), DraftSnapshot.t()}

  @spec snapshot_write_mode(state(), state(), snapshot_write_mode()) :: snapshot_write_mode()
  defp snapshot_write_mode(previous, candidate, :preserve) do
    if TurnExecution.pending_inputs(previous.turn_execution) ==
         TurnExecution.pending_inputs(candidate.turn_execution) do
      :preserve
    else
      :queue_transition
    end
  end

  defp snapshot_write_mode(_previous, _candidate, mode), do: mode

  @spec begin_native_dispatch(state(), pid(), String.t(), Dispatch.source()) ::
          {:reply, {:ok, Dispatch.t(), [ReqLLM.Message.t()]} | {:error, term()}, state()}
  defp begin_native_dispatch(state, worker, request_id, source) do
    {steering, notices, execution} = dispatch_inputs(state, source)
    {canonical, display} = steering_inputs(steering)
    notice = job_notice_message(notices)

    with {:ok, dispatch, messages, continuation} <-
           Continuation.begin_dispatch(
             state.continuation,
             request_id,
             source,
             canonical,
             notice,
             worker
           ),
         candidate =
           state
           |> deliver_job_notices(notices)
           |> install_dispatch_source(continuation, execution, display),
         {:ok, committed} <- persist_dispatch_source(state, candidate) do
      committed =
        committed
        |> publish_job_notices(notices)
        |> publish_dispatched_steering(display)

      {:reply, {:ok, dispatch, messages}, committed}
    else
      {:error, reason} -> {:reply, {:error, {:request_admission_failed, reason}}, state}
    end
  end

  @spec install_dispatch_source(state(), Continuation.t(), TurnExecution.t(), [Message.t()]) ::
          state()
  defp install_dispatch_source(state, continuation, execution, []),
    do: %{state | continuation: continuation, turn_execution: execution}

  defp install_dispatch_source(state, continuation, execution, display) do
    %{state | continuation: continuation, turn_execution: execution}
    |> append_msgs(display)
    |> Map.update!(:transcript, &Transcript.touch(&1, DateTime.utc_now()))
  end

  # The initial request and a retry's frozen source are already committed. Only new steering alters storage.
  @spec persist_dispatch_source(state(), state()) :: {:ok, state()} | {:error, term()}
  defp persist_dispatch_source(
         %{continuation: %Continuation{tool_checkpoint: %{version: 1}}} = state,
         %{continuation: %Continuation{tool_checkpoint: %{version: 2}}} = candidate
       ),
       do: commit_effect_snapshot(state, candidate)

  defp persist_dispatch_source(_state, candidate), do: {:ok, candidate}

  # Queued steering and pending job notices enter only the first dispatch after a checkpoint, which
  # freezes them once. A retry against the frozen checkpoint takes neither, so notices stay pending.
  @spec dispatch_inputs(state(), Dispatch.source()) ::
          {[TurnExecution.content()], [JobRecord.t()], TurnExecution.t()}
  defp dispatch_inputs(
         %{continuation: %Continuation{tool_checkpoint: %{checkpoint_id: id, version: 1}}} = state,
         {:checkpoint, id}
       ) do
    {steering, execution} = TurnExecution.dequeue_steering(state.turn_execution)
    {steering, JobLedger.pending_notices(state.job_ledger), execution}
  end

  defp dispatch_inputs(state, _source), do: {[], [], state.turn_execution}

  @spec publish_dispatched_steering(state(), [Message.t()]) :: state()
  defp publish_dispatched_steering(state, []), do: state

  defp publish_dispatched_steering(state, messages) do
    Enum.each(messages, &record_user_message_event(state, &1))
    notify_messages_changed(state)
  end

  @spec assess_native_dispatch(
          state(),
          Dispatch.t(),
          binary(),
          RequestCapacity.t()
        ) :: {:reply, :ok | {:error, term()}, state()}
  defp assess_native_dispatch(state, attempt, digest, %RequestCapacity{limits: limits} = evidence) do
    with %ModelSelection{policy: %{limits: ^limits}} = selection <- state.model_selection,
         true <- ModelSelection.id(selection) == attempt.selection_id,
         {:ok, continuation} <-
           Continuation.assess_dispatch(state.continuation, attempt, digest, evidence) do
      {:reply, evidence.decision, %{state | continuation: continuation}}
    else
      _stale -> {:reply, {:error, :stale_dispatch}, state}
    end
  end

  @spec saved_model_selection(state()) :: ModelSelection.t() | Stored.t() | nil
  defp saved_model_selection(%{model_selection: nil, unresolved_route: {stored, _intent}}),
    do: stored

  defp saved_model_selection(state), do: state.model_selection

  @spec saved_selection_intent(state()) :: map()
  defp saved_selection_intent(%{model_selection: nil, unresolved_route: {_stored, intent}})
       when is_map(intent),
       do: intent

  defp saved_selection_intent(state), do: %{"model" => state.provider.model_name}

  @spec save_to_disk(state(), snapshot_write_mode()) :: :ok | {:error, term()}

  defp save_to_disk(state, draft_revision \\ :preserve) do
    if Persistence.enabled?(state.persistence) do
      now = DateTime.to_iso8601(DateTime.utc_now())
      last_message_at = DateTime.to_iso8601(Transcript.last_changed_at(state.transcript))
      {messages, message_ids} = Transcript.messages_and_ids(state.transcript)

      data = %{
        id: state.session_id,
        timestamp: now,
        last_message_at: last_message_at,
        title:
          readable_title(first_assistant_text(messages)) ||
            readable_title(first_user_prompt(messages)),
        model_name: state.provider.model_name,
        provider_name: state.provider.provider_name,
        model_selection: saved_model_selection(state),
        selection_intent: saved_selection_intent(state),
        messages: messages,
        message_ids: message_ids,
        pinned_ids: Transcript.pinned_ids(state.transcript),
        usage: Transcript.usage(state.transcript),
        branches: Transcript.branches(state.transcript),
        memory: Memory.read(state.session_store_dir),
        checklist: state.checklist,
        checklist_archive: state.checklist_archive,
        file_changes: state.file_changes,
        job_ledger: state.job_ledger,
        pending_inputs: TurnExecution.pending_inputs(state.turn_execution),
        continuation: state.continuation
      }

      case draft_revision do
        :preserve ->
          SessionStore.save(data, state.session_store_dir, artifact_store_opts(state))

        :queue_transition ->
          opts = [{:confirm_queue_commit, true} | artifact_store_opts(state)]
          confirm_queue_snapshot(SessionStore.save(data, state.session_store_dir, opts))

        {:queued_draft, revision} ->
          confirm_queue_snapshot(
            SessionStore.save_queued_draft(
              data,
              revision,
              state.session_store_dir,
              artifact_store_opts(state)
            )
          )

        {:recalled_draft, revision, draft} ->
          confirm_queue_snapshot(
            SessionStore.save_recalled_draft(
              data,
              revision,
              draft,
              state.session_store_dir,
              artifact_store_opts(state)
            )
          )

        revision ->
          SessionStore.save_submitted_draft(
            data,
            revision,
            state.session_store_dir,
            artifact_store_opts(state)
          )
      end
    else
      :ok
    end
  end

  @spec confirm_queue_snapshot(:ok | {:error, term()}) :: :ok | {:error, term()}
  defp confirm_queue_snapshot({:error, {:queue_commit_uncertain, _, _}}),
    do: exit(:queue_commit_uncertain)

  defp confirm_queue_snapshot(result), do: result

  @spec artifact_store_opts(state()) :: keyword()
  defp artifact_store_opts(%{artifact_runtime: nil}), do: []

  defp artifact_store_opts(%{artifact_runtime: %ArtifactRuntime{} = runtime}),
    do: [artifact_runtime: runtime]

  @spec rename_saved_conversation(state(), ConnectionTarget.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp rename_saved_conversation(state, target, title) do
    with :ok <- validate_connection_target(state, target),
         :ok <- validate_composer_record(state, state.session_id) do
      SessionStore.rename_conversation(
        state.session_id,
        title,
        state.session_store_dir,
        artifact_store_opts(state)
      )
    end
  end

  @spec set_saved_archive_status(state(), ConnectionTarget.t(), boolean()) ::
          :ok | {:error, term()}
  defp set_saved_archive_status(state, target, archived?) do
    with :ok <- validate_connection_target(state, target),
         :ok <- validate_composer_record(state, state.session_id) do
      SessionStore.set_archived(
        state.session_id,
        archived?,
        state.session_store_dir,
        artifact_store_opts(state)
      )
    end
  end

  @spec validate_composer_record(state(), String.t()) ::
          :ok | {:error, :not_persistent | :stale_target}
  defp validate_composer_record(%{session_id: record_id} = state, record_id) do
    if Persistence.enabled?(state.persistence), do: :ok, else: {:error, :not_persistent}
  end

  defp validate_composer_record(_state, _record_id), do: {:error, :stale_target}

  @spec inspect_composer_attachment(state(), String.t(), DraftAttachment.identity()) ::
          {:ok, DraftSnapshot.attachment(), String.t()} | {:error, term()}
  defp inspect_composer_attachment(state, record_id, identity) do
    with :ok <- validate_composer_record(state, record_id) do
      SessionStore.read_draft_attachment(
        record_id,
        identity,
        state.session_store_dir,
        artifact_store_opts(state)
      )
    end
  end

  @spec handle_remote_composer(state(), String.t(), remote_composer_operation()) ::
          {:reply, composer_result(), state()} | {:stop, term(), composer_result(), state()}
  defp handle_remote_composer(
         state,
         record_id,
         {:submit, revision, submission_id, shown, content}
       )
       when is_integer(revision) and revision >= 0 and is_binary(submission_id) and
              byte_size(submission_id) == 24 and is_list(shown) and
              (is_binary(content) or is_list(content)) do
    case remote_draft_prompt(state, record_id, shown, content) do
      {:ok, ^revision, prompt} -> handle_draft_prompt(state, prompt, {revision, submission_id})
      {:ok, current, _prompt} -> {:reply, {:error, {:stale_draft_revision, current}}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  defp handle_remote_composer(
         state,
         record_id,
         {:queue, {record_id, _, _} = target, kind, draft, content}
       ),
       do: handle_queued_draft(state, target, kind, draft, content)

  defp handle_remote_composer(state, _record_id, {:queue, _, _, _, _}),
    do: {:reply, {:error, :stale_target}, state}

  defp handle_remote_composer(state, record_id, {:confirm_queue_receipt, {_, _, _, _} = receipt}),
    do: acknowledge_queue_receipt(state, record_id, receipt)

  defp handle_remote_composer(state, record_id, {:reconcile_submission, revision, submission_id})
       when is_integer(revision) and revision >= 0 and is_binary(submission_id) and
              byte_size(submission_id) == 24 do
    result =
      SessionStore.composer_admission(
        record_id,
        revision,
        submission_id,
        state.session_store_dir,
        artifact_store_opts(state)
      )

    {:reply, result, state}
  end

  defp handle_remote_composer(
         state,
         record_id,
         {:inspect_attachment, {token, revision} = identity}
       )
       when is_binary(token) and is_binary(revision),
       do: {:reply, inspect_composer_attachment(state, record_id, identity), state}

  defp handle_remote_composer(state, _record_id, :read_queue),
    do: {:reply, {:ok, pending_input_summaries(state.turn_execution)}, state}

  defp handle_remote_composer(state, record_id, {:withdraw_queued_input, {id, revision}})
       when is_integer(id) and id > 0 and is_integer(revision) and revision > 0,
       do: change_queued_input_reply(state, record_id, id, revision, :remove)

  defp handle_remote_composer(state, record_id, {:read_queued_input_text, identity}),
    do: {:reply, queued_input_text_result(state, record_id, identity), state}

  defp handle_remote_composer(state, record_id, {:edit_queued_input, {id, revision}, text})
       when is_integer(id) and id > 0 and is_integer(revision) and revision > 0 and
              is_binary(text),
       do:
         change_queued_input_reply(state, record_id, id, revision, {:replace_prompt, text, text})

  defp handle_remote_composer(state, record_id, operation),
    do: {:reply, composer_draft(state, record_id, operation), state}

  @spec acknowledge_queue_receipt(state(), String.t(), TurnExecution.queue_receipt()) ::
          {:reply, :ok | {:error, term()}, state()}
  defp acknowledge_queue_receipt(state, record_id, receipt) do
    with :ok <- validate_composer_record(state, record_id),
         {:ok, execution} <- TurnExecution.confirm_queue_receipt(state.turn_execution, receipt),
         {:ok, committed} <- commit_effect_snapshot(state, %{state | turn_execution: execution}) do
      {:reply, :ok, committed}
    else
      :unchanged -> {:reply, :ok, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @spec remote_draft_prompt(state(), String.t(), [DraftAttachment.identity()], content) ::
          {:ok, SessionStore.draft_revision(), content} | {:error, term()}
        when content: String.t() | [ReqLLM.Message.ContentPart.t()]
  defp remote_draft_prompt(state, record_id, [], content) do
    case composer_draft(state, record_id, :read) do
      {:ok, revision, nil} -> {:ok, revision, content}
      {:ok, revision, %DraftSnapshot{attachments: []}} -> {:ok, revision, content}
      {:ok, _revision, _draft} -> {:error, :draft_attachments_changed}
      {:error, _reason} = error -> error
    end
  end

  defp remote_draft_prompt(state, record_id, shown, content) do
    with {:ok, revision, retained} <-
           SessionStore.resolve_draft_attachments(
             record_id,
             shown,
             state.session_store_dir,
             artifact_store_opts(state)
           ),
         {:ok, prompt} <-
           DraftAttachment.append_to_prompt(content, retained, state.model_selection) do
      {:ok, revision, prompt}
    end
  end

  @spec schedule_save_retry(state()) :: state()
  defp schedule_save_retry(state) do
    {persistence, delay_ms} = Persistence.failed(state.persistence)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:save_session, token}, delay_ms)
    %{state | persistence: Persistence.scheduled(persistence, token, timer_ref)}
  end

  @spec composer_draft(state(), String.t(), composer_draft_operation()) ::
          {:ok, SessionStore.draft_revision(), DraftSnapshot.t() | nil}
          | {:ok, SessionStore.draft_revision(), DraftSnapshot.attachment()}
          | {:ok, SessionStore.draft_revision()}
          | {:ok, TurnExecution.queue_receipt()}
          | {:error, term()}
  defp composer_draft(state, record_id, :read) do
    SessionStore.read_presentation(record_id, state.session_store_dir, artifact_store_opts(state))
  end

  defp composer_draft(state, record_id, {:reconcile_queue, sequence, token, previous}) do
    case TurnExecution.queued_submission(state.turn_execution, sequence, token) do
      {:queued, receipt} -> {:ok, receipt}
      _missing -> missing_queue_receipt(state, record_id, previous)
    end
  end

  defp composer_draft(state, record_id, {:save, expected, draft})
       when is_integer(expected) and expected >= 0 do
    SessionStore.save_presentation(
      record_id,
      expected,
      draft,
      state.session_store_dir,
      artifact_store_opts(state)
    )
  end

  defp composer_draft(state, record_id, {:remove_attachment, expected, draft})
       when is_integer(expected) and expected >= 0 do
    SessionStore.save_attachment_removal(
      record_id,
      expected,
      draft,
      state.session_store_dir,
      artifact_store_opts(state)
    )
  end

  defp composer_draft(state, record_id, {:attach_text, expected, draft, snapshot})
       when is_integer(expected) and expected >= 0 and is_struct(draft, DraftSnapshot) and
              is_list(draft.attachments) do
    SessionStore.attach_text(
      record_id,
      expected,
      draft,
      snapshot,
      state.session_store_dir,
      artifact_store_opts(state)
    )
  end

  defp composer_draft(_state, _record_id, _operation), do: {:error, :invalid_draft_operation}

  @spec missing_queue_receipt(state(), String.t(), SessionStore.draft_revision()) ::
          {:error, :queue_receipt_missing | :queue_receipt_unconfirmed}
  defp missing_queue_receipt(state, record_id, previous) do
    case composer_draft(state, record_id, :read) do
      {:ok, ^previous, _draft} -> {:error, :queue_receipt_missing}
      _changed_or_unavailable -> {:error, :queue_receipt_unconfirmed}
    end
  end

  @spec restore_draft_only_session(state(), String.t()) :: {:reply, term(), state()}
  defp restore_draft_only_session(state, record_id) do
    with true <- Persistence.enabled?(state.persistence) || {:error, :not_persistent},
         :ok <- persist_current_before_replacement(state, record_id),
         {:ok, reservation} <- reserve_session_identity(state, record_id) do
      case commit_session_identity(state, reservation) do
        :ok ->
          now = DateTime.utc_now()
          execution = TurnExecution.restore(state.turn_execution)

          staged = %{
            state
            | session_id: record_id,
              custom_title: nil,
              archived?: false,
              transcript: state.transcript |> Transcript.reset([]) |> Transcript.touch(now),
              continuation: Continuation.reset(state.continuation),
              checklist: Checklist.new(),
              checklist_archive: ChecklistArchive.new(),
              file_changes: [],
              job_ledger: JobLedger.new()
          }

          {:ok, restored} = install_loaded_session_state(state, staged, execution, now)
          {:reply, :ok, restored}

        {:error, reason} ->
          abort_session_identity(state, reservation)
          {:reply, {:error, {:session_identity_commit_failed, reason}}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @spec begin_loaded_session_restore(
          state(),
          SessionStore.session_data(),
          GenServer.from()
        ) :: {:reply, term(), state()} | {:noreply, state()}
  defp begin_loaded_session_restore(state, data, _from) do
    route = resolve_saved_model_selection(state, data)

    case restore_loaded_session(state, data, route) do
      {:ok, restored} -> {:reply, :ok, restored}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @spec restore_loaded_session(state(), SessionStore.session_data(), saved_route()) ::
          {:ok, state()} | {:error, term()}
  defp restore_loaded_session(state, data, route) do
    case persist_current_before_replacement(state, data.id) do
      :ok -> reserve_loaded_session(state, data, route)
      {:error, reason} -> {:error, {:save_current_failed, reason}}
    end
  end

  @spec reserve_loaded_session(state(), SessionStore.session_data(), saved_route()) ::
          {:ok, state()} | {:error, term()}
  defp reserve_loaded_session(state, data, route) do
    case reserve_session_identity(state, data.id) do
      {:ok, reservation} -> restore_reserved_session(state, data, route, reservation)
      {:error, _reason} = error -> error
    end
  end

  @spec restore_reserved_session(
          state(),
          SessionStore.session_data(),
          saved_route(),
          SessionManager.identity_reservation() | :unchanged | :unmanaged
        ) :: {:ok, state()} | {:error, term()}
  defp restore_reserved_session(state, data, route, reservation) do
    case restore_loaded_candidate(state, data, route, reservation) do
      {:ok, _restored} = result ->
        result

      {:error, _reason} = error ->
        abort_session_identity(state, reservation)
        error
    end
  end

  @spec reserve_session_identity(state(), String.t()) ::
          {:ok, SessionManager.identity_reservation() | :unchanged | :unmanaged}
          | {:error, term()}
  defp reserve_session_identity(%{session_manager: nil}, _target_id), do: {:ok, :unmanaged}
  defp reserve_session_identity(%{session_id: target_id}, target_id), do: {:ok, :unchanged}

  defp reserve_session_identity(state, target_id) do
    SessionManager.reserve_session_identity(state.session_manager, target_id)
  end

  @spec commit_session_identity(
          state(),
          SessionManager.identity_reservation() | :unchanged | :unmanaged
        ) ::
          :ok | {:error, term()}
  defp commit_session_identity(_state, reservation) when reservation in [:unchanged, :unmanaged],
    do: :ok

  defp commit_session_identity(state, reservation) do
    SessionManager.commit_session_identity(state.session_manager, reservation)
  end

  @spec abort_session_identity(
          state(),
          SessionManager.identity_reservation() | :unchanged | :unmanaged
        ) :: :ok
  defp abort_session_identity(_state, reservation) when reservation in [:unchanged, :unmanaged],
    do: :ok

  defp abort_session_identity(state, reservation) do
    SessionManager.abort_session_identity(state.session_manager, reservation)
  end

  # A saved route that cannot resolve now (ambiguous, removed, or missing its credential) does not
  # block access to the saved history. The session opens without a selection and retains the
  # resolution problem, so the connection snapshot shows the route as unavailable with its remedy.
  @spec resolve_saved_model_selection(state(), SessionStore.session_data()) :: saved_route()
  defp resolve_saved_model_selection(
         %{provider: %{module: MingaAgent.Providers.Native}} = state,
         data
       ) do
    opts = model_resolution_opts(state)

    result =
      case Map.get(data, :model_selection) do
        %ModelSelection{} = selection ->
          ModelResolver.restore(selection, opts)

        %Stored{} = stored ->
          ModelResolver.restore(stored, opts)

        nil ->
          intent = Map.get(data, :selection_intent, %{"model" => data.model_name})
          ModelResolver.resolve(intent, opts)
      end

    case result do
      {:ok, selection} -> {:resolved, selection}
      {:error, reason} -> {:unresolved, reason}
    end
  end

  defp resolve_saved_model_selection(_state, _data), do: {:resolved, nil}

  # Sessions saved before the selection problem moved to the connection snapshot stored it as a
  # permanent transcript error. A restore now retains any current selection problem in the
  # connection snapshot, so that old notice is never current and must not be shown.
  @spec drop_retired_selection_notices(Transcript.t()) :: Transcript.t()
  defp drop_retired_selection_notices(transcript) do
    retained =
      for {id, message} <- Transcript.messages_with_ids(transcript),
          not retired_selection_notice?(message),
          do: id

    Transcript.compact(transcript, retained)
  end

  @spec retired_selection_notice?(Message.t()) :: boolean()
  defp retired_selection_notice?({:system, "Model selection needs correction: " <> _, :error}),
    do: true

  defp retired_selection_notice?(_message), do: false

  @spec restore_loaded_candidate(
          state(),
          SessionStore.session_data(),
          saved_route(),
          SessionManager.identity_reservation() | :unchanged | :unmanaged
        ) :: {:ok, state()} | {:error, term()}
  defp restore_loaded_candidate(state, data, route, reservation) do
    {selection, resolution_problem} = saved_route_selection(route)
    unresolved_route = saved_unresolved_route(route, data)
    loaded_at = parse_datetime(Map.get(data, :last_message_at)) || DateTime.utc_now()
    model_name = selection_model_name(selection, data.model_name)
    provider_name = if selection, do: selection.route.model_provider, else: data.provider_name

    provider_opts =
      state.provider.opts
      |> Keyword.put(:model, model_name)
      |> maybe_put_model_selection(selection)

    lifecycle =
      ProviderLifecycle.replace(
        state.provider,
        model_name,
        provider_name,
        provider_opts
      )

    transcript =
      Transcript.restore(
        state.transcript,
        data.messages,
        data.message_ids,
        Map.get(data, :branches, []),
        data.usage,
        Map.get(data, :pinned_ids, MapSet.new()),
        loaded_at
      )
      |> drop_retired_selection_notices()

    execution =
      TurnExecution.restore_pending_inputs(Map.get(data, :pending_inputs, {1, [], [], []}))

    {credential_readiness, credentials_configured} =
      loaded_selection_readiness(state, selection)

    candidate = %{
      state
      | session_id: data.id,
        custom_title: Map.get(data, :custom_title),
        archived?: Map.get(data, :archived?, false),
        transcript: transcript,
        continuation: data.continuation,
        checklist: Map.get(data, :checklist, Checklist.new()),
        checklist_archive: Map.get(data, :checklist_archive, ChecklistArchive.new()),
        file_changes: Map.get(data, :file_changes, []),
        job_ledger:
          JobLedger.restore(Map.get(data, :job_ledger, JobLedger.new()), DateTime.utc_now()),
        provider: lifecycle,
        credential_readiness: credential_readiness,
        credentials_configured: credentials_configured,
        model_selection: selection,
        unresolved_route: unresolved_route,
        connection: Connection.resolved(state.connection, resolution_problem),
        turn_execution: execution,
        pending_model_change: nil,
        created_at: loaded_at
    }

    with {:ok, staged, reconciled?} <- reconcile_loaded_checkpoint(candidate),
         {:ok, staged} <- prepare_reconciliation_warning(staged, reconciled?),
         {:ok, staged} <- restore_loaded_route_provider(staged, state.model_selection, route) do
      restore_loaded_memory_candidate(
        state,
        data,
        staged,
        execution,
        loaded_at,
        reservation
      )
    end
  end

  @spec saved_route_selection(saved_route()) ::
          {ModelSelection.t() | nil, ModelResolver.resolution_error() | nil}
  defp saved_route_selection({:resolved, selection}), do: {selection, nil}
  defp saved_route_selection({:unresolved, reason}), do: {nil, reason}

  @spec saved_unresolved_route(saved_route(), SessionStore.session_data()) ::
          unresolved_route() | nil
  defp saved_unresolved_route({:resolved, _selection}, _data), do: nil

  defp saved_unresolved_route({:unresolved, _reason}, data) do
    stored =
      case Map.get(data, :model_selection) do
        %Stored{} = stored -> stored
        _absent -> nil
      end

    {stored, Map.get(data, :selection_intent)}
  end

  # An unresolved saved route has no exact selection to hand the provider, so the provider is
  # neither started nor retargeted here. Installation stops any previous provider once the
  # restore commits; prompts stay refused until the user chooses a route.
  @spec restore_loaded_route_provider(state(), ModelSelection.t() | nil, saved_route()) ::
          {:ok, state()} | {:error, {:provider_model_restore_failed, term()}}
  defp restore_loaded_route_provider(staged, current_selection, {:resolved, _selection}),
    do: restore_loaded_provider_model(staged, current_selection)

  defp restore_loaded_route_provider(staged, _current_selection, {:unresolved, _reason}),
    do: {:ok, staged}

  @spec loaded_selection_readiness(state(), ModelSelection.t() | nil) ::
          {Credentials.readiness(), boolean()}
  defp loaded_selection_readiness(_state, %ModelSelection{}), do: {:configured, true}

  defp loaded_selection_readiness(
         %{provider: %{module: MingaAgent.Providers.Native}},
         nil
       ) do
    {:unconfigured, false}
  end

  defp loaded_selection_readiness(state, nil) do
    {state.credential_readiness, state.credentials_configured}
  end

  @spec restore_loaded_memory_candidate(
          state(),
          SessionStore.session_data(),
          state(),
          TurnExecution.t(),
          DateTime.t(),
          SessionManager.identity_reservation() | :unchanged | :unmanaged
        ) :: {:ok, state()} | {:error, term()}
  defp restore_loaded_memory_candidate(
         state,
         data,
         staged,
         execution,
         loaded_at,
         reservation
       ) do
    case restore_loaded_memory(staged, data) do
      :ok ->
        install_loaded_session(state, staged, execution, loaded_at, reservation)

      {:error, memory_error} ->
        rollback_loaded_memory_restore(
          staged,
          state.model_selection,
          state.provider,
          memory_error
        )
    end
  end

  @spec rollback_loaded_memory_restore(
          state(),
          ModelSelection.t() | nil,
          ProviderLifecycle.t(),
          term()
        ) :: {:error, term()}
  defp rollback_loaded_memory_restore(
         staged,
         previous_selection,
         previous_provider,
         memory_error
       ) do
    case rollback_loaded_provider_model(staged, previous_selection, previous_provider) do
      :ok ->
        {:error, memory_error}

      {:error, rollback_error} ->
        {:error, {:restore_rollback_failed, memory_error, rollback_error}}
    end
  end

  @spec restore_loaded_memory(state(), SessionStore.session_data()) ::
          :ok | {:error, {:memory_restore_failed, term()}}
  defp restore_loaded_memory(state, data) do
    case restore_memory_snapshot_if_recorded(state, data) do
      :ok -> :ok
      {:error, reason} -> {:error, {:memory_restore_failed, reason}}
    end
  end

  @spec restore_loaded_provider_model(state(), ModelSelection.t() | nil) ::
          {:ok, state()} | {:error, {:provider_model_restore_failed, term()}}
  defp restore_loaded_provider_model(state, current_selection) do
    case apply_loaded_model_to_provider(state, current_selection) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, {:provider_model_restore_failed, reason}}
    end
  end

  @spec install_loaded_session(
          state(),
          state(),
          TurnExecution.t(),
          DateTime.t(),
          SessionManager.identity_reservation() | :unchanged | :unmanaged
        ) :: {:ok, state()} | {:error, term()}
  defp install_loaded_session(state, staged, execution, loaded_at, reservation) do
    case commit_session_identity(state, reservation) do
      :ok ->
        install_loaded_session_state(state, staged, execution, loaded_at)

      {:error, reason} ->
        case rollback_loaded_provider_model(staged, state.model_selection, state.provider) do
          :ok -> {:error, {:session_identity_commit_failed, reason}}
          {:error, rollback_error} -> {:error, {:restore_rollback_failed, reason, rollback_error}}
        end
    end
  end

  @spec install_loaded_session_state(
          state(),
          state(),
          TurnExecution.t(),
          DateTime.t()
        ) :: {:ok, state()}
  defp install_loaded_session_state(state, staged, execution, loaded_at) do
    current =
      state
      |> cancel_save_timer()
      |> restore_turn_execution(execution)

    {persistence, timer_to_cancel} = Persistence.restored(current.persistence)
    cancel_runtime_timer(timer_to_cancel)

    loaded = %{
      current
      | session_id: staged.session_id,
        custom_title: staged.custom_title,
        archived?: staged.archived?,
        transcript: staged.transcript,
        continuation: staged.continuation,
        checklist: staged.checklist,
        checklist_archive: staged.checklist_archive,
        file_changes: staged.file_changes,
        persistence: persistence,
        provider: staged.provider,
        credential_readiness: staged.credential_readiness,
        credentials_configured: staged.credentials_configured,
        model_selection: staged.model_selection,
        unresolved_route: staged.unresolved_route,
        turn_execution: execution,
        tool_authority: %{current.tool_authority | revision: make_ref(), invocations: %{}},
        pending_model_change: nil,
        created_at: loaded_at
    }

    loaded = install_job_ledger(loaded, staged.job_ledger)
    loaded = invalidate_connection(loaded, :conversation)
    loaded = retain_resolution_problem(loaded, staged.connection.resolver_problem)
    loaded = settle_loaded_provider(loaded, state.provider)
    finish_loaded_session_restore(loaded)
  end

  # A restored route that did not resolve has no provider to attach. The previous session's
  # provider must not keep serving the restored conversation, so it stops; its retry timer and
  # lease go with it. No attachment effects (onboarding notice, SessionStart hook, manager
  # notification) run, because no provider started.
  @spec settle_loaded_provider(state(), ProviderLifecycle.t()) :: state()
  defp settle_loaded_provider(%{unresolved_route: {_stored, _intent}} = state, _previous),
    do: stop_provider_lifecycle(state)

  defp settle_loaded_provider(state, previous),
    do: finish_loaded_provider_attachment(state, previous)

  @spec finish_loaded_provider_attachment(state(), ProviderLifecycle.t()) :: state()
  defp finish_loaded_provider_attachment(state, previous)
       when ProviderLifecycle.is_detached(previous) do
    {:reset, _lifecycle, retry_timer} = ProviderLifecycle.reset_retry(previous)
    cancel_provider_retry_timer(retry_timer)
    finish_provider_attachment(state)
  end

  defp finish_loaded_provider_attachment(state, _previous), do: state

  @spec finish_loaded_session_restore(state()) :: {:ok, state()}
  defp finish_loaded_session_restore(state) do
    state = publish_connection(state)
    broadcast(state, {:status_changed, :idle})
    broadcast(state, :messages_changed)

    # A restored ledger can owe notices, for example for jobs that a restart interrupted.
    {:ok, state |> publish_checklist() |> wake_for_job_notices()}
  end

  @spec reconcile_loaded_checkpoint(state()) ::
          {:ok, state(), boolean()} | {:error, {:checkpoint_reconciliation_failed, term()}}
  defp reconcile_loaded_checkpoint(
         %{continuation: %Continuation{tool_checkpoint: nil, active_request: nil}} = state
       ),
       do: {:ok, state, false}

  defp reconcile_loaded_checkpoint(%{continuation: %Continuation{tool_checkpoint: nil}} = state) do
    candidate =
      state
      |> Map.put(:continuation, Continuation.interrupt_request(state.continuation))
      |> append_system_message(
        "Recovered an interrupted provider request. Its exact user prompt is preserved for the next continuation.",
        :error
      )

    case commit_loaded_checkpoint_snapshot(state, candidate) do
      {:ok, committed} -> {:ok, committed, true}
      {:error, reason} -> {:error, {:checkpoint_reconciliation_failed, reason}}
    end
  end

  defp reconcile_loaded_checkpoint(state) do
    case reconciliation_outputs(state) do
      {:ok, outputs} ->
        transcript_id = boundary_transcript_id(state.transcript)

        {continuation, reconciliation} =
          Continuation.reconcile_interrupted(
            state.continuation,
            transcript_id,
            outputs
          )

        indeterminate_count = Enum.count(reconciliation, &(&1.status == :indeterminate))
        not_executed_count = Enum.count(reconciliation, &(&1.status == :not_executed))

        message =
          "Recovered an interrupted provider tool-call group without replaying any call. " <>
            "#{indeterminate_count} admitted call(s) now have an explicit indeterminate result; " <>
            "#{not_executed_count} unadmitted call(s) are marked not executed. " <>
            "The exact provider continuation was preserved for the next request."

        candidate =
          state
          |> Map.put(:continuation, continuation)
          |> freeze_checklist(transcript_id)
          |> reconcile_transcript_tool_calls(reconciliation)
          |> append_system_message(message, if(indeterminate_count == 0, do: :info, else: :error))

        case commit_loaded_checkpoint_snapshot(state, candidate) do
          {:ok, committed} -> {:ok, committed, true}
          {:error, reason} -> {:error, {:checkpoint_reconciliation_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:checkpoint_reconciliation_failed, reason}}
    end
  end

  @spec commit_loaded_checkpoint_snapshot(state(), state()) :: {:ok, state()} | {:error, term()}
  defp commit_loaded_checkpoint_snapshot(state, candidate) do
    if Persistence.enabled?(state.persistence) do
      candidate = %{
        candidate
        | continuation: Continuation.mark_durable(candidate.continuation)
      }

      case save_to_disk(candidate) do
        :ok -> {:ok, candidate}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :session_persistence_disabled}
    end
  end

  @spec prepare_reconciliation_warning(state(), boolean()) :: {:ok, state()} | {:error, term()}
  defp prepare_reconciliation_warning(state, true), do: {:ok, state}

  defp prepare_reconciliation_warning(state, false) do
    case EventLog.open_read_connection() do
      {:ok, db} ->
        try do
          case all_event_log_events(db, state.session_id) do
            {:ok, events} ->
              interrupted =
                Enum.filter(
                  events,
                  &(&1.event_type in [:tool_call_interrupted, :approval_interrupted])
                )

              case interrupted do
                [] ->
                  {:ok, state}

                _events ->
                  message =
                    "Earlier admitted work was interrupted. Its outcome is treated as indeterminate and Minga will not rerun it automatically."

                  {:ok, append_system_message(state, message, :error)}
              end

            {:error, reason} ->
              {:error, {:event_log_reconciliation_failed, reason}}
          end
        after
          MingaAgent.EventLog.Store.close(db)
        end

      {:error, :database_not_found} ->
        {:ok, state}

      {:error, reason} ->
        {:error, {:event_log_reconciliation_failed, reason}}
    end
  rescue
    _error -> {:error, :event_log_reconciliation_failed}
  end

  @spec apply_loaded_model_to_provider(state(), ModelSelection.t() | nil) ::
          {:ok, state()} | {:error, term()}
  defp apply_loaded_model_to_provider(%{provider: provider} = state, _current_selection)
       when ProviderLifecycle.is_detached(provider) do
    start_loaded_provider(state)
  end

  defp apply_loaded_model_to_provider(state, current_selection) do
    argument = provider_model_argument(state)

    case dispatch_optional(state.provider.module, :set_model, [
           ProviderLifecycle.pid(state.provider),
           argument
         ]) do
      :ok ->
        {:ok, state}

      {:error, :not_supported}
      when current_selection != nil and current_selection == state.model_selection ->
        {:ok, state}

      {:error, reason} ->
        {:error, reason}

      result ->
        {:error, {:unexpected_model_restore_result, result}}
    end
  catch
    :exit, reason -> {:error, {:provider_unavailable, reason}}
  end

  @spec start_loaded_provider(state()) :: {:ok, state()} | {:error, term()}
  defp start_loaded_provider(state) do
    lifecycle = state.provider

    if provider_startable?(lifecycle.module, lifecycle.opts, lifecycle.model_name) do
      {:reset, lifecycle, _previous_retry_timer} = ProviderLifecycle.reset_retry(lifecycle)
      {:start, lifecycle, retry_timer} = ProviderLifecycle.start(lifecycle)
      cancel_provider_retry_timer(retry_timer)
      candidate = %{state | provider: lifecycle}

      case start_provider(candidate) do
        {:ok, pid, started} ->
          {:ok, attach_provider_process(started, pid)}

        {:error, reason, failed} ->
          {:failed, lifecycle, lease} = ProviderLifecycle.failure(failed.provider, reason)
          release_provider_lease(lease)
          _failed = %{failed | provider: lifecycle}
          {:error, reason}
      end
    else
      {:error, :provider_not_startable}
    end
  end

  @spec rollback_loaded_provider_model(
          state(),
          ModelSelection.t() | nil,
          ProviderLifecycle.t()
        ) :: :ok | {:error, term()}
  defp rollback_loaded_provider_model(state, _current_selection, previous_provider)
       when ProviderLifecycle.is_detached(previous_provider) do
    _stopped = stop_provider_lifecycle(state)
    :ok
  end

  defp rollback_loaded_provider_model(state, current_selection, _previous_provider)
       when current_selection == state.model_selection,
       do: :ok

  defp rollback_loaded_provider_model(state, current_selection, _previous_provider) do
    argument =
      if state.provider.module == MingaAgent.Providers.Native,
        do: current_selection,
        else: state.provider.model_name

    case dispatch_optional(state.provider.module, :set_model, [
           ProviderLifecycle.pid(state.provider),
           argument
         ]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      result -> {:error, {:unexpected_model_rollback_result, result}}
    end
  catch
    :exit, reason -> {:error, {:provider_unavailable, reason}}
  end

  @spec provider_model_argument(state()) :: ModelSelection.t() | String.t() | nil
  defp provider_model_argument(%{
         provider: %{module: MingaAgent.Providers.Native},
         model_selection: selection
       }),
       do: selection

  defp provider_model_argument(state), do: state.provider.model_name

  @spec persist_current_before_replacement(state(), String.t()) :: :ok | {:error, term()}
  defp persist_current_before_replacement(%{session_id: target_id}, target_id), do: :ok

  defp persist_current_before_replacement(state, _target_id),
    do: state |> durable_save_candidate() |> save_to_disk()

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
    temporary_path = path <> ".restore.tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary_path, memory),
         :ok <- File.rename(temporary_path, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary_path)
        {:error, reason}
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

  @spec legacy_import_id(String.t()) :: String.t()
  defp legacy_import_id(source_id) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    "#{source_id}-portable-#{suffix}"
  end

  @spec prepare_legacy_import(SessionStore.session_data(), String.t()) ::
          SessionStore.session_data()
  defp prepare_legacy_import(data, imported_id) do
    imported_notice =
      "Imported legacy display history. Continuation is reconstructed and may omit provider signatures, tool groups, or attachments; the original record was preserved."

    message_ids = Map.fetch!(data, :message_ids)
    next_message_id = Enum.reduce(message_ids, 0, &max/2) + 1

    data
    |> Map.put(:id, imported_id)
    |> Map.put(:messages, Enum.concat(data.messages, [{:system, imported_notice, :info}]))
    |> Map.put(:message_ids, Enum.concat(message_ids, [next_message_id]))
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
  @spec format_status(map()) :: map()
  def format_status(status) do
    status = status |> Map.replace(:state, :redacted) |> Map.replace(:log, :redacted)

    case status do
      %{message: {:submit_queued_draft, _, _, _, _}} ->
        status |> Map.replace(:message, :submit_queued_draft) |> Map.replace(:reason, :redacted)

      %{message: {:composer_draft, _, _, _, {:queue, _, _, _, _}}} ->
        status |> Map.replace(:message, :submit_queued_draft) |> Map.replace(:reason, :redacted)

      %{message: {:confirm_queue_receipt, _, _, _}} ->
        status |> Map.replace(:message, :confirm_queue_receipt) |> Map.replace(:reason, :redacted)

      %{message: {:composer_draft, _, _, _, {:recall, _, _, _}}} ->
        status |> Map.replace(:message, :recall_queued_draft) |> Map.replace(:reason, :redacted)

      %{message: {:change_queued_input, _, _, _}} ->
        status |> Map.replace(:message, :change_queued_input) |> Map.replace(:reason, :redacted)

      %{message: {:remote_composer, _, _, _}} ->
        status |> Map.replace(:message, :remote_composer) |> Map.replace(:reason, :redacted)

      _other ->
        status
    end
  end

  @impl GenServer
  @spec terminate(term(), state()) :: :ok
  def terminate(reason, state) do
    Notifier.clear_approval()

    record_critical_event(state, :session_stopped, %{
      reason: inspect(reason),
      status: TurnExecution.status(state.turn_execution)
    })

    dispatch_session_end(state, reason)
    reap_job_owner(state.job_owner)
    retire_connection_dependencies(state.connection, :cancel)
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

  # SessionStart hooks are notification-only, so their result cannot change the
  # session. They run in a supervised task: a slow hook command never holds the
  # session process, and so never holds the Editor or Ingest calls queued on it.
  defp dispatch_session_start(state) do
    payload =
      state.session_id
      |> SessionStartPayload.new(
        state.provider.model_name,
        state.provider.provider_name,
        session_start_root(state)
      )
      |> SessionStartPayload.to_map()

    case Task.Supervisor.start_child(state.hook_task_supervisor, fn ->
           run_session_start_hooks(payload)
         end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> log_session_start_failure(reason)
    end
  catch
    :exit, reason -> log_session_start_failure(reason)
  end

  @spec run_session_start_hooks(map()) :: :ok
  defp run_session_start_hooks(payload) do
    Minga.Telemetry.span([:minga, :agent, :session_start_hooks], %{}, fn ->
      hooks =
        Minga.Telemetry.span([:minga, :agent, :session_start_hook_config], %{}, fn ->
          AgentConfig.agent_hooks()
        end)

      HookDispatcher.session_start(hooks, payload)
    end)
  rescue
    e -> Minga.Log.warning(:agent, "SessionStart hook dispatch failed: #{Exception.message(e)}")
  catch
    _, reason -> log_session_start_failure(reason)
  end

  @spec log_session_start_failure(term()) :: :ok
  defp log_session_start_failure(reason) do
    Minga.Log.warning(:agent, "SessionStart hook dispatch failed: #{inspect(reason)}")
  end

  @spec dispatch_session_end(state(), term()) :: :ok
  defp dispatch_session_end(%{hooks_enabled?: false}, _reason), do: :ok

  defp dispatch_session_end(state, reason) do
    payload =
      SessionEndPayload.new(state.session_id, reason, TurnExecution.status(state.turn_execution))

    HookDispatcher.session_end(
      AgentConfig.agent_hooks(),
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
    HookDispatcher.stop(AgentConfig.agent_hooks(), StopPayload.to_map(payload))
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
      AgentConfig.agent_hooks(),
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
      AgentConfig.agent_hooks(),
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
