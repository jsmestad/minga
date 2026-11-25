defmodule MingaEditor.State.AgentConnection do
  @moduledoc """
  Agent provider configuration and live editor ingest connection.

  Provider configuration, the local arrival budget and the session manager that starts local sessions are immutable after startup; the ingest process may be replaced as the editor's supervised agent integration restarts. `route_usage` holds the plan usage contributed model routes last reported.

  `tasks` is every task the editor follows (`MingaEditor.Agent.Tasks`): each session's latest state and open approval, whichever tab shows it.

  `transcript_sync` is the one transcript read the Editor has out to its active local Session (`MingaEditor.Agent.TranscriptSync`).

  `turn_requests` holds each composer send and stop the Editor has out to a Session (`MingaEditor.Agent.TurnRequest`).

  `arrival_budget_ms` is the time a local Agent tab arrival waits for its Session before it shows the tab as unavailable (`MingaEditor.Agent.Arrival`).
  """

  alias MingaAgent.InferenceRoute.StatusChangedEvent
  alias MingaEditor.Agent.Arrival
  alias MingaEditor.Agent.SessionFollowUp
  alias MingaEditor.Agent.SessionStart
  alias MingaEditor.Agent.Tasks
  alias MingaEditor.Agent.TranscriptSync
  alias MingaEditor.Agent.TurnRequest
  alias MingaEditor.State.RouteUsage

  @default_arrival_budget_ms 250

  @type t :: %__MODULE__{
          agent_ingest: pid() | nil,
          agent_provider_module: module() | nil,
          agent_provider_opts: keyword(),
          arrival_budget_ms: non_neg_integer(),
          question_receipts: %{pid() => binary()},
          arrival: Arrival.t() | nil,
          transcript_sync: TranscriptSync.t() | nil,
          session_manager: GenServer.server(),
          session_starts: %{reference() => SessionStart.t()},
          session_follow_ups: %{reference() => SessionFollowUp.t()},
          turn_requests: %{reference() => TurnRequest.t()},
          route_usage: RouteUsage.t(),
          tasks: Tasks.t()
        }

  @derive {Inspect, except: [:question_receipts]}
  defstruct agent_ingest: nil,
            agent_provider_module: nil,
            agent_provider_opts: [],
            arrival_budget_ms: @default_arrival_budget_ms,
            question_receipts: %{},
            arrival: nil,
            transcript_sync: nil,
            session_manager: MingaAgent.SessionManager,
            session_starts: %{},
            session_follow_ups: %{},
            turn_requests: %{},
            route_usage: %RouteUsage{},
            tasks: %Tasks{}

  @doc "The production local arrival budget in milliseconds."
  @spec default_arrival_budget_ms() :: non_neg_integer()
  def default_arrival_budget_ms, do: @default_arrival_budget_ms

  @doc "Creates agent connection state from startup provider and arrival configuration."
  @spec new(module() | nil, keyword(), non_neg_integer()) :: t()
  def new(
        provider_module \\ nil,
        provider_opts \\ [],
        arrival_budget_ms \\ @default_arrival_budget_ms
      )
      when is_list(provider_opts) and is_integer(arrival_budget_ms) and arrival_budget_ms >= 0 do
    %__MODULE__{
      agent_provider_module: provider_module,
      agent_provider_opts: provider_opts,
      arrival_budget_ms: arrival_budget_ms
    }
  end

  @doc "Records the supervised stream-ingest process serving this editor."
  @spec connect_ingest(t(), pid() | nil) :: t()
  def connect_ingest(%__MODULE__{} = connection, ingest)
      when is_pid(ingest) or is_nil(ingest),
      do: %{connection | agent_ingest: ingest}

  @doc "Keeps the private remote driver receipt only in live editor memory."
  @spec remember_question_receipt(t(), pid(), binary()) :: t()
  def remember_question_receipt(%__MODULE__{} = connection, session, receipt)
      when is_pid(session) and is_binary(receipt) and byte_size(receipt) == 32 do
    %{connection | question_receipts: Map.put(connection.question_receipts, session, receipt)}
  end

  @doc "Drops a remote driver's local receipt when its session goes away."
  @spec forget_question_receipt(t(), pid()) :: t()
  def forget_question_receipt(%__MODULE__{} = connection, session) when is_pid(session),
    do: %{connection | question_receipts: Map.delete(connection.question_receipts, session)}

  @doc "Keeps the active tab's outstanding local Session request in the owning Editor."
  @spec install_arrival(t(), Arrival.t() | nil) :: t()
  def install_arrival(%__MODULE__{} = connection, arrival), do: %{connection | arrival: arrival}

  @doc "Keeps the Editor's one outstanding transcript read, or clears it."
  @spec install_transcript_sync(t(), TranscriptSync.t() | nil) :: t()
  def install_transcript_sync(%__MODULE__{} = connection, sync),
    do: %{connection | transcript_sync: sync}

  @doc "Keeps a local Session start request the Editor sent and has not finished."
  @spec track_session_start(t(), SessionStart.t()) :: t()
  def track_session_start(%__MODULE__{} = connection, %SessionStart{token: token} = start),
    do: %{connection | session_starts: Map.put(connection.session_starts, token, start)}

  @doc "Forgets a finished local Session start request."
  @spec finish_session_start(t(), reference()) :: t()
  def finish_session_start(%__MODULE__{} = connection, token) when is_reference(token),
    do: %{connection | session_starts: Map.delete(connection.session_starts, token)}

  @doc "Keeps a follow-up request the Editor sent to a newly started Session and has not settled."
  @spec track_session_follow_up(t(), SessionFollowUp.t()) :: t()
  def track_session_follow_up(
        %__MODULE__{} = connection,
        %SessionFollowUp{token: token} = follow_up
      ),
      do: %{
        connection
        | session_follow_ups: Map.put(connection.session_follow_ups, token, follow_up)
      }

  @doc "Forgets a settled follow-up request."
  @spec finish_session_follow_up(t(), reference()) :: t()
  def finish_session_follow_up(%__MODULE__{} = connection, token) when is_reference(token),
    do: %{connection | session_follow_ups: Map.delete(connection.session_follow_ups, token)}

  @doc "Keeps a composer send or a stop the Editor sent to a Session and has not seen answered."
  @spec track_turn_request(t(), TurnRequest.t()) :: t()
  def track_turn_request(%__MODULE__{} = connection, %TurnRequest{token: token} = request),
    do: %{connection | turn_requests: Map.put(connection.turn_requests, token, request)}

  @doc "Forgets an answered send or stop."
  @spec finish_turn_request(t(), reference()) :: t()
  def finish_turn_request(%__MODULE__{} = connection, token) when is_reference(token),
    do: %{connection | turn_requests: Map.delete(connection.turn_requests, token)}

  @doc "Records a contributed route's reported status for the modeline."
  @spec record_route_status(t(), StatusChangedEvent.t()) :: t()
  def record_route_status(%__MODULE__{} = connection, %StatusChangedEvent{} = event),
    do: %{connection | route_usage: RouteUsage.record(connection.route_usage, event)}

  @doc "Applies one session event to the task it belongs to, at wall-clock time `now`."
  @spec observe_task_event(t(), pid(), term(), integer()) :: t()
  def observe_task_event(%__MODULE__{} = connection, session, event, now) when is_pid(session),
    do: %{connection | tasks: Tasks.observe(connection.tasks, session, event, now)}

  @doc "Starts following a session as a task. Options as `MingaEditor.Agent.Tasks.follow/4`."
  @spec follow_task(t(), pid(), integer(), keyword()) :: t()
  def follow_task(%__MODULE__{} = connection, session, now, opts \\ []) when is_pid(session),
    do: %{connection | tasks: Tasks.follow(connection.tasks, session, now, opts)}

  @doc "Shows a task the drawer started before its session binds; returns the row's sequence number too."
  @spec start_task(t(), reference(), String.t(), integer()) :: {t(), non_neg_integer()}
  def start_task(%__MODULE__{} = connection, id, title, now) do
    {tasks, seq} = Tasks.start(connection.tasks, id, title, now)
    {%{connection | tasks: tasks}, seq}
  end

  @doc "Turns a starting task into the task of the session that bound for it."
  @spec bind_task(t(), reference(), pid(), integer()) :: t()
  def bind_task(%__MODULE__{} = connection, id, session, now),
    do: %{connection | tasks: Tasks.bind(connection.tasks, id, session, now)}

  @doc "Shows that a starting task's session could not start."
  @spec fail_task_start(t(), reference(), String.t()) :: t()
  def fail_task_start(%__MODULE__{} = connection, id, message),
    do: %{connection | tasks: Tasks.start_failed(connection.tasks, id, message)}

  @doc "Carries a task over to the session that replaced its crashed one."
  @spec replace_task_session(t(), pid(), pid(), integer()) :: t()
  def replace_task_session(%__MODULE__{} = connection, old, new, now),
    do: %{connection | tasks: Tasks.replace(connection.tasks, old, new, now)}

  @doc "Stops following every task on a node that disconnected."
  @spec forget_node_tasks(t(), node()) :: t()
  def forget_node_tasks(%__MODULE__{} = connection, node),
    do: %{connection | tasks: Tasks.forget_node(connection.tasks, node)}

  @doc "Stops following a session that ended."
  @spec forget_task(t(), pid()) :: t()
  def forget_task(%__MODULE__{} = connection, session),
    do: %{connection | tasks: Tasks.forget(connection.tasks, session)}

  @doc "Clears a task's approval once its session accepted an answer or said none is pending."
  @spec resolve_task_approval(t(), pid(), MingaAgent.ToolApproval.Target.t()) :: t()
  def resolve_task_approval(%__MODULE__{} = connection, session, target),
    do: %{connection | tasks: Tasks.resolve_approval(connection.tasks, session, target)}
end
