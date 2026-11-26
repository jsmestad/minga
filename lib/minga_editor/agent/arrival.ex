defmodule MingaEditor.Agent.Arrival do
  @moduledoc """
  A local Agent tab arrival holds one Session request at a time. Both requests share the Editor's arrival budget (`MingaEditor.State.AgentConnection`). Only the final capture in the Session's ordinary event order can install live controls.
  A timely reply holds the previous committed frame until that ordered capture
  arrives or the same deadline expires.
  """

  alias MingaAgent.Session
  alias MingaEditor.Agent.Events
  alias MingaEditor.Agent.SessionEventWorkflow
  alias MingaEditor.Agent.StatusEventWorkflow
  alias MingaEditor.Agent.UIState
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.Workflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab

  @typep phase ::
           {:snapshot, :gen_server.request_id()}
           | {:capture, :gen_server.request_id()}
           | {:committing, reference()}
           | :forwarded
  @type t :: %__MODULE__{
          token: reference(),
          tab: Tab.id(),
          session: pid(),
          phase: phase()
        }
  @enforce_keys [:token, :tab, :session, :phase]
  defstruct @enforce_keys

  @doc "Begins an exact local arrival with one shared deadline for Session I/O."
  @spec start(EditorState.t(), Tab.id(), pid()) :: EditorState.t()
  def start(
        %EditorState{agent_connection: %{agent_ingest: subscriber, arrival_budget_ms: budget}} =
          state,
        tab,
        session
      )
      when is_pid(subscriber) and is_pid(session) and node(session) == node() do
    deadline = System.monotonic_time(:millisecond) + budget
    state = state |> cancel() |> Workflow.install_agent_cache_reset() |> unavailable()
    request = Session.request_editor_snapshot(session)

    pending = %__MODULE__{
      token: make_ref(),
      tab: tab,
      session: session,
      phase: {:snapshot, request}
    }

    await(state, pending, deadline)
  end

  def start(%EditorState{} = state, _tab, _session),
    do: state |> cancel() |> Workflow.install_agent_cache_reset() |> unavailable()

  @doc "Cancels interest in the outgoing arrival without cancelling Session work."
  @spec cancel(EditorState.t()) :: EditorState.t()
  def cancel(%EditorState{agent_connection: %{arrival: nil}} = state), do: state

  def cancel(%EditorState{agent_connection: %{arrival: pending}} = state) do
    case pending.phase do
      {:committing, timer} -> Process.cancel_timer(timer, async: true, info: false)
      {_step, request} -> :gen_server.receive_response(request, 0)
      :forwarded -> :ok
    end

    EditorState.install_agent_arrival(state, nil)
  end

  @doc "Retires only the stopped Session's outstanding arrival."
  @spec retire(EditorState.t(), pid()) :: EditorState.t()
  def retire(
        %EditorState{agent_connection: %{arrival: %__MODULE__{session: session}}} = state,
        session
      ),
      do: cancel(state)

  def retire(%EditorState{} = state, _session), do: state

  @doc "Tells the Editor whether Session controls must wait for the ordered arrival capture."
  @spec pending?(EditorState.t(), pid() | nil) :: boolean()
  def pending?(
        %EditorState{agent_connection: %{arrival: %__MODULE__{session: session} = pending}} =
          state,
        session
      ),
      do: current?(state, pending)

  def pending?(%EditorState{}, _session), do: false

  @doc "Keeps the last committed frame while a timely Session capture crosses Ingest."
  @spec defer_frame?(EditorState.t()) :: boolean()
  def defer_frame?(
        %EditorState{
          agent_connection: %{arrival: %__MODULE__{phase: {:committing, _timer}} = pending}
        } = state
      ),
      do: current?(state, pending)

  def defer_frame?(%EditorState{}), do: false

  @doc "Shows Unavailable if the ordered capture has not arrived by the switch deadline."
  @spec presentation_deadline(EditorState.t(), reference()) :: EditorState.t()
  def presentation_deadline(
        %EditorState{
          agent_connection: %{
            arrival: %__MODULE__{token: token, phase: {:committing, _}} = pending
          }
        } = state,
        token
      ) do
    if current?(state, pending) do
      state
      |> EditorState.install_agent_arrival(%{pending | phase: :forwarded})
      |> AgentLifecycle.report_unavailable_arrival(2)
      |> MingaEditor.do_render()
    else
      cancel(state)
    end
  end

  def presentation_deadline(%EditorState{} = state, _token), do: state

  @doc "Waits for the ordered snapshot only for live controls; other events retain their effects."
  @spec dispatch_before_capture(EditorState.t(), pid(), term()) :: EditorState.t()
  def dispatch_before_capture(state, _session, event)
      when elem(event, 0) in [
             :approval_pending,
             :approval_resolved,
             :question_requested,
             :question_answered,
             :question_cancelled,
             :question_interrupted,
             :queue_target_changed,
             :stop_target_changed,
             :continue_target_changed
           ],
      do: state

  def dispatch_before_capture(state, session, {:connection_changed, _connection} = event) do
    waiting = state.workspace.agent_ui.chat_lifecycle
    updated = Events.dispatch(state, session, event)

    Workflow.install_agent_ui(
      updated,
      UIState.restore_chat(updated.workspace.agent_ui, waiting)
    )
  end

  def dispatch_before_capture(state, _session, {:error, message}),
    do: SessionEventWorkflow.error(state, message, :arrival)

  def dispatch_before_capture(state, session, event), do: Events.dispatch(state, session, event)

  @doc "Handles an OTP reply or request monitor without intercepting unrelated messages."
  @spec response(EditorState.t(), term()) :: {:handled, EditorState.t()} | :unrelated
  def response(
        %EditorState{
          agent_connection: %{arrival: %__MODULE__{phase: {step, request}} = pending}
        } = state,
        message
      )
      when step in [:snapshot, :capture] do
    case :gen_server.check_response(message, request) do
      :no_reply -> :unrelated
      reply -> {:handled, apply_if_current(state, pending, reply)}
    end
  end

  def response(%EditorState{}, _message), do: :unrelated

  @doc "Installs the complete capture only for the active matching arrival."
  @spec ready(EditorState.t(), pid(), reference(), Session.editor_arrival()) :: EditorState.t()
  def ready(
        %EditorState{
          agent_connection: %{
            arrival: %__MODULE__{session: session, token: token, phase: phase} = pending
          }
        } = state,
        session,
        token,
        capture
      )
      when phase == :forwarded or elem(phase, 0) in [:capture, :committing] do
    if current?(state, pending) do
      state
      |> cancel()
      |> install_capture(session, capture)
    else
      cancel(state)
    end
  end

  def ready(%EditorState{} = state, _session, _token, _capture), do: state

  @spec install_capture(EditorState.t(), pid(), Session.editor_arrival()) :: EditorState.t()
  defp install_capture(state, session, {snapshot, _transcript} = capture) do
    state
    |> AgentLifecycle.apply_editor_arrival(session, capture)
    |> StatusEventWorkflow.display_status_changed(session, snapshot.display_status)
  end

  @spec current?(EditorState.t(), t()) :: boolean()
  defp current?(state, %__MODULE__{tab: tab, session: session}) do
    match?(%Tab{id: ^tab, kind: :agent}, Runtime.active_tab(state.shell_runtime)) and
      Runtime.active_session(state.shell_runtime) == session
  end

  @spec await(EditorState.t(), t(), integer()) :: EditorState.t()
  defp await(state, %__MODULE__{phase: {_, request}} = pending, deadline) do
    budget = max(deadline - System.monotonic_time(:millisecond), 0)

    case :gen_server.wait_response(request, budget) do
      :timeout ->
        state
        |> EditorState.install_agent_arrival(pending)
        |> report_unavailable(pending)

      reply ->
        advance(state, pending, reply, deadline)
    end
  end

  @spec apply_if_current(EditorState.t(), t(), term()) :: EditorState.t()
  defp apply_if_current(state, pending, reply) do
    if current?(state, pending) do
      advance(state, pending, reply, :async)
    else
      EditorState.install_agent_arrival(state, nil)
    end
  end

  @spec advance(EditorState.t(), t(), term(), integer() | :async) :: EditorState.t()
  defp advance(
         state,
         %__MODULE__{phase: {:snapshot, _}} = pending,
         {:reply, %{status: _}},
         deadline
       ) do
    subscriber = state.agent_connection.agent_ingest
    cursor = state.workspace.agent_ui.panel.transcript.source_cursor || :snapshot
    request = Session.request_editor_arrival(pending.session, cursor, subscriber, pending.token)
    pending = %{pending | phase: {:capture, request}}

    case deadline do
      :async -> EditorState.install_agent_arrival(state, pending)
      deadline -> await(state, pending, deadline)
    end
  end

  defp advance(state, %__MODULE__{phase: {:capture, _}} = pending, {:reply, :forwarded}, :async) do
    EditorState.install_agent_arrival(state, %{pending | phase: :forwarded})
  end

  defp advance(state, %__MODULE__{phase: {:capture, _}} = pending, {:reply, :forwarded}, deadline) do
    timer =
      Process.send_after(self(), {:agent_arrival_deadline, pending.token}, deadline, abs: true)

    EditorState.install_agent_arrival(state, %{pending | phase: {:committing, timer}})
  end

  defp advance(state, pending, _failure, deadline) do
    state
    |> EditorState.install_agent_arrival(nil)
    |> fail_arrival(pending, deadline)
    |> MingaEditor.schedule_render(16)
  end

  @spec fail_arrival(EditorState.t(), t(), integer() | :async) :: EditorState.t()
  defp fail_arrival(state, _pending, :async), do: state
  defp fail_arrival(state, pending, _deadline), do: report_unavailable(state, pending)

  @spec report_unavailable(EditorState.t(), t()) :: EditorState.t()
  defp report_unavailable(state, %__MODULE__{phase: {step, _request}}) do
    calls = if step == :snapshot, do: 1, else: 2
    AgentLifecycle.report_unavailable_arrival(state, calls)
  end

  @spec unavailable(EditorState.t()) :: EditorState.t()
  defp unavailable(state) do
    Workflow.install_agent_ui(
      state,
      UIState.transition_chat(state.workspace.agent_ui, :unavailable)
    )
  end
end
