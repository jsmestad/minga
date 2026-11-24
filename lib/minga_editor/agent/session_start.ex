defmodule MingaEditor.Agent.SessionStart do
  @moduledoc """
  A local Agent session start that the Editor requested and has not finished.

  The Editor never waits for a session to start. It sends one `:gen_server.send_request/2` to `MingaAgent.SessionManager` and keeps this record until the reply arrives. The request names the Editor's subscriber (Ingest, or the Editor when Ingest is down) as an initial subscriber, so the session attaches it inside `init/1` and no subscribe call waits behind provider start or SessionStart hooks.

  The session's first event through that subscriber is `{:session_start_attached, token}`. It is ordered ahead of every other event from the session, so the Editor binds the session at the earlier of that event and the manager's reply, and never drops an event from a session it has not bound yet. The starting tab stays in the `:starting` chat state until the session's connection reports a running provider.

  The manager's error reply, the manager's exit, or the start deadline marks the starting tab failed and keeps its draft. A start that succeeds after its deadline is stopped when its reply arrives. These functions return the next state; the Editor schedules the render.
  """

  alias MingaAgent.ProjectView
  alias MingaAgent.SessionManager
  alias MingaEditor.Agent.SessionFollowUp
  alias MingaEditor.Agent.StartFailure
  alias MingaEditor.Agent.StartRequest
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Shell.Traditional.Workflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.Agent, as: WorkspaceAgent
  alias MingaEditor.WorkspaceWorkflow

  @timeout_ms 15_000

  @typedoc "Work that needs the started session, run once it is bound to its workspace."
  @type follow_up :: nil | SessionFollowUp.work()

  @typedoc """
  `{:awaiting, timer}` until the session binds or fails; `{:bound, pid}` after the attach event bound it ahead of the reply; `:abandoned` after the deadline marked the tab failed.
  """
  @type phase :: {:awaiting, reference()} | {:bound, pid()} | :abandoned

  @type t :: %__MODULE__{
          token: reference(),
          request: :gen_server.request_id(),
          workspace: non_neg_integer(),
          project_view: ProjectView.t() | nil,
          created_project_view?: boolean(),
          start_request: StartRequest.t(),
          phase: phase()
        }

  @enforce_keys [
    :token,
    :request,
    :workspace,
    :project_view,
    :created_project_view?,
    :start_request,
    :phase
  ]
  defstruct @enforce_keys

  @doc """
  Sends the start request for the agent workspace `workspace_id` and returns at once.

  `session_opts` are the Session start options. The project view travels with the request so the session never needs a second call to learn it. `start_request` is kept so a failed start can offer to run again unchanged; its follow-up runs only once the session binds.
  """
  @spec request(
          EditorState.t(),
          non_neg_integer(),
          keyword(),
          {ProjectView.t() | nil, boolean()},
          StartRequest.t()
        ) :: EditorState.t()
  def request(
        state,
        workspace_id,
        session_opts,
        {project_view, created?},
        %StartRequest{} = start_request
      ) do
    token = make_ref()

    opts =
      session_opts
      |> Keyword.put(:subscribers, [{subscriber(state), [questions?: true]}])
      |> Keyword.put(:start_token, token)

    request = SessionManager.request_start_session(state.agent_connection.session_manager, opts)
    timer = Process.send_after(self(), {:agent_session_start_timeout, token}, @timeout_ms)

    EditorState.track_agent_session_start(state, %__MODULE__{
      token: token,
      request: request,
      workspace: workspace_id,
      project_view: project_view,
      created_project_view?: created?,
      start_request: start_request,
      phase: {:awaiting, timer}
    })
  end

  @doc "Tells whether `workspace_id` already has a start in flight, so a second open does not start another session."
  @spec pending?(EditorState.t(), non_neg_integer() | nil) :: boolean()
  def pending?(%EditorState{agent_connection: %{session_starts: starts}}, workspace_id) do
    Enum.any?(starts, fn {_token, start} ->
      start.workspace == workspace_id and match?({:awaiting, _timer}, start.phase)
    end)
  end

  @doc "Binds the session named by the first event in its ordered stream."
  @spec attached(EditorState.t(), pid(), reference()) :: EditorState.t()
  def attached(%EditorState{agent_connection: %{session_starts: starts}} = state, session, token)
      when is_pid(session) do
    case Map.get(starts, token) do
      %__MODULE__{phase: {:awaiting, timer}} = start ->
        cancel_timer(timer)

        state
        |> EditorState.track_agent_session_start(%{start | phase: {:bound, session}})
        |> bind(start, session)

      _settled ->
        state
    end
  end

  @doc "Handles a start reply or request monitor without intercepting unrelated messages."
  @spec response(EditorState.t(), term()) :: {:handled, EditorState.t()} | :unrelated
  def response(%EditorState{agent_connection: %{session_starts: starts}} = state, message) do
    Enum.find_value(starts, :unrelated, fn {_token, start} ->
      case :gen_server.check_response(message, start.request) do
        :no_reply -> nil
        reply -> {:handled, settle(state, start, reply)}
      end
    end)
  end

  @doc "Shows a failure in the starting tab once the start deadline passes."
  @spec timeout(EditorState.t(), reference()) :: EditorState.t()
  def timeout(%EditorState{agent_connection: %{session_starts: starts}} = state, token) do
    case Map.get(starts, token) do
      %__MODULE__{phase: {:awaiting, _timer}} = start ->
        state
        |> EditorState.track_agent_session_start(%{start | phase: :abandoned})
        |> fail(start, StartFailure.timed_out(start.start_request), :timeout)

      _settled ->
        state
    end
  end

  @spec settle(EditorState.t(), t(), term()) :: EditorState.t()
  defp settle(state, %__MODULE__{phase: {:awaiting, timer}} = start, reply) do
    cancel_timer(timer)
    state = EditorState.finish_agent_session_start(state, start.token)

    case reply do
      {:reply, {:ok, _session_id, session}} -> bind(state, start, session)
      {:reply, {:error, reason}} -> session_error(state, start, reason)
      {:error, {reason, _manager}} -> session_error(state, start, reason)
    end
  end

  defp settle(state, %__MODULE__{phase: :abandoned} = start, {:reply, {:ok, _id, session}}) do
    stop_orphan(session)
    EditorState.finish_agent_session_start(state, start.token)
  end

  defp settle(state, %__MODULE__{} = start, _reply),
    do: EditorState.finish_agent_session_start(state, start.token)

  @spec bind(EditorState.t(), t(), pid()) :: EditorState.t()
  defp bind(state, start, session) do
    tabs = Runtime.traditional_tab_bar(state.shell_runtime)

    case tabs && TabBar.get_workspace(tabs, start.workspace) do
      %Workspace{payload: %WorkspaceAgent{remote_session: nil}} = workspace ->
        # The active workspace's live UI is on the Editor state; a stored copy is stale.
        workspace =
          workspace
          |> Workspace.set_session(session)
          |> Workspace.set_project_view(start.project_view)
          |> clear_stored_ui(Runtime.active_workspace?(state.shell_runtime, start.workspace))

        state
        |> WorkspaceWorkflow.install_tab_bar(TabBar.accept_workspace(tabs, workspace))
        |> install_started_runtime(start.workspace, session)
        |> run_follow_up(start, session)

      _closed_or_remote ->
        discard_project_view(start)
        stop_orphan(session)
        state
    end
  end

  @spec clear_stored_ui(Workspace.agent(), boolean()) :: Workspace.agent()
  defp clear_stored_ui(workspace, true), do: Workspace.set_agent_ui(workspace, nil)
  defp clear_stored_ui(workspace, false), do: workspace

  # The fresh session is idle with nothing pending. Its chat stays `:starting`
  # until the connection event reports the provider running.
  @spec install_started_runtime(EditorState.t(), non_neg_integer(), pid()) :: EditorState.t()
  defp install_started_runtime(state, workspace_id, session) do
    if Runtime.active_workspace?(state.shell_runtime, workspace_id) do
      agent =
        state.shell_runtime.state
        |> TraditionalState.agent()
        |> AgentState.apply_session_snapshot(session, :idle, nil, nil, nil)

      Workflow.install_agent_state(state, agent)
    else
      state
    end
  end

  @spec run_follow_up(EditorState.t(), t(), pid()) :: EditorState.t()
  defp run_follow_up(
         state,
         %__MODULE__{start_request: %StartRequest{follow_up: follow_up}} = start,
         session
       ),
       do: SessionFollowUp.run(state, start.workspace, session, follow_up)

  # The raw reason is logged here; the tab shows only the failure's plain sentence.
  @spec session_error(EditorState.t(), t(), term()) :: EditorState.t()
  defp session_error(state, start, reason),
    do: fail(state, start, StartFailure.session_error(reason, start.start_request), reason)

  @spec fail(EditorState.t(), t(), StartFailure.t(), term()) :: EditorState.t()
  defp fail(state, start, %StartFailure{} = failure, reason) do
    Minga.Log.error(:agent, "[Agent] #{failure.message} (#{inspect(reason)})")
    discard_project_view(start)
    tabs = Runtime.traditional_tab_bar(state.shell_runtime)

    case tabs && TabBar.get_workspace(tabs, start.workspace) do
      %Workspace{payload: %WorkspaceAgent{}} = workspace ->
        show_failure(state, tabs, workspace, failure)

      _closed ->
        state
    end
  end

  @spec show_failure(EditorState.t(), TabBar.t(), Workspace.agent(), StartFailure.t()) ::
          EditorState.t()
  defp show_failure(state, tabs, %Workspace{id: id} = workspace, failure) do
    cond do
      Runtime.active_workspace?(state.shell_runtime, id) ->
        Workflow.install_agent_ui(state, UIState.fail_start(state.workspace.agent_ui, failure))

      match?(%UIState{}, workspace.payload.agent_ui) ->
        ui = UIState.fail_start(workspace.payload.agent_ui, failure)

        WorkspaceWorkflow.install_tab_bar(
          state,
          TabBar.accept_workspace(tabs, Workspace.set_agent_ui(workspace, ui))
        )

      true ->
        state
    end
  end

  @spec subscriber(EditorState.t()) :: pid()
  defp subscriber(%EditorState{agent_connection: %{agent_ingest: ingest}}) when is_pid(ingest),
    do: ingest

  defp subscriber(%EditorState{}), do: self()

  @spec discard_project_view(t()) :: :ok
  defp discard_project_view(%__MODULE__{
         project_view: %ProjectView{} = view,
         created_project_view?: true
       }) do
    ProjectView.discard(view)
  catch
    :exit, _ -> :ok
  end

  defp discard_project_view(%__MODULE__{}), do: :ok

  # A session nobody displays is stopped off the Editor; the manager may be
  # busy starting another session.
  @spec stop_orphan(pid()) :: :ok
  defp stop_orphan(session) do
    Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, fn ->
      SessionManager.stop_session_by_pid(session)
    end)

    :ok
  catch
    :exit, _ -> :ok
  end

  @spec cancel_timer(reference()) :: :ok
  defp cancel_timer(timer) do
    Process.cancel_timer(timer, async: true, info: false)
    :ok
  end
end
