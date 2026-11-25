defmodule MingaEditor.Handlers.SessionHandler do
  @moduledoc """
  Owns session recovery, persistence, and periodic timer actions.

  `dispatch/2` snapshots immutable persistence input first and applies focused
  actions in order. Timer ownership stays in the Editor process. Session saves
  and startup recovery reads are admitted to their domain-owned typed effects,
  whose workers are supervised by the Editor generation's effect scheduler.
  Headless mode keeps canceling the save timer and does not initiate startup
  recovery. Admission failures retain safe state and use each effect's warning
  or transient-state policy.
  """

  alias Minga.Session
  alias MingaEditor.Session.Capture
  alias MingaEditor.Session.Recovery
  alias MingaEditor.Session.Save
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Session, as: SessionState

  @typedoc "Focused actions owned by the session workflow."
  @type session_effect ::
          {:save_session_async, Session.snapshot(), keyword()}
          | {:restart_session_timer}
          | {:cancel_session_timer}
          | {:recover_session_async, keyword(), keyword(), boolean(), boolean()}

  @doc "Applies one session event and its focused persistence/timer actions."
  @spec dispatch(EditorState.t(), term()) :: EditorState.t()
  def dispatch(%EditorState{} = state, message) do
    {state, effects} = handle(state, message)
    apply_effects(state, effects)
  end

  @doc "Computes focused actions for one session event without filesystem I/O."
  @spec handle(EditorState.t(), term()) :: {EditorState.t(), [session_effect()]}
  def handle(state, :check_swap_recovery), do: handle_check_swap_recovery(state)
  def handle(state, :save_session), do: handle_save_session(state)
  def handle(state, _msg), do: {state, []}

  @spec apply_effects(EditorState.t(), [session_effect()]) :: EditorState.t()
  defp apply_effects(state, []), do: state

  defp apply_effects(state, [effect | rest]) do
    state = apply_effect(state, effect)
    apply_effects(state, rest)
  end

  @spec apply_effect(EditorState.t(), session_effect()) :: EditorState.t()
  defp apply_effect(state, {:save_session_async, snapshot, opts}),
    do: Save.schedule(state, snapshot, opts)

  defp apply_effect(state, {:restart_session_timer}) do
    {:restart_timer, session, timer} = SessionState.restart_timer(state.session)
    cancel_timer(timer)

    case SessionState.start_timer(session) do
      {:no_timer, session} ->
        %{state | session: session}

      {:start_timer, session} ->
        ref = Process.send_after(self(), :save_session, SessionState.timer_interval())
        %{state | session: SessionState.accept_timer(session, ref)}
    end
  end

  defp apply_effect(state, {:cancel_session_timer}) do
    {:cancel_timer, session, timer} = SessionState.cancel_timer(state.session)
    cancel_timer(timer)
    %{state | session: session}
  end

  defp apply_effect(
         state,
         {:recover_session_async, swap_opts, session_opts, swap_enabled?, session_enabled?}
       ) do
    Recovery.schedule(state, swap_opts, session_opts, swap_enabled?, session_enabled?)
  end

  @spec handle_check_swap_recovery(EditorState.t()) ::
          {EditorState.t(), [session_effect()]}
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  # A headless editor never scans swap files, but it restores a project session when one is configured, so the storyboard factory can drive `minga .` with a saved session.
  defp handle_check_swap_recovery(state) do
    recovery_effects(
      state,
      swap_recovery_enabled?(state),
      restore_enabled?(state),
      SessionState.swap_opts(state.session),
      project_session_opts(state)
    )
  end

  @doc "True when startup scans swap files: never for a headless editor."
  @spec swap_recovery_enabled?(EditorState.t()) :: boolean()
  def swap_recovery_enabled?(%EditorState{} = state) do
    state.frontend.backend != :headless and SessionState.swap_enabled?(state.session)
  end

  @doc """
  The session options for the editor's project: the configured session directory plus the project root, so every project keeps its own session file.
  """
  @spec project_session_opts(EditorState.t()) :: keyword()
  def project_session_opts(%EditorState{} = state) do
    SessionState.session_opts(state.session) ++
      [project_root: Capture.project_root(state.workspace)]
  end

  @doc "True when this editor owns its project's session: persistence is on, there is a project root, and the editor opened the project rather than one file."
  @spec persists_project?(EditorState.t()) :: boolean()
  def persists_project?(%EditorState{} = state) do
    SessionState.enabled?(state.session) and SessionState.project_session?(state.session) and
      is_binary(Capture.project_root(state.workspace))
  end

  @doc """
  True when opening the project should restore its saved session.

  The editor must own the project's session (`persists_project?/1`), and the workspace must still be empty: a file opened in the meantime wins over the saved session.
  """
  @spec restore_enabled?(EditorState.t()) :: boolean()
  def restore_enabled?(%EditorState{} = state) do
    persists_project?(state) and state.workspace.buffers.list == []
  end

  @doc """
  Saves the session now, in the calling process.

  Used on quit, where the periodic save would be too late. Does nothing outside a project or with persistence off.
  """
  @spec save_now(EditorState.t()) :: :ok
  def save_now(%EditorState{} = state) do
    if persists_project?(state) do
      case Session.save(Capture.snapshot(state), project_session_opts(state)) do
        :ok -> :ok
        {:error, reason} -> Minga.Log.warning(:editor, "Session save failed: #{inspect(reason)}")
      end
    end

    :ok
  end

  @spec recovery_effects(
          EditorState.t(),
          boolean(),
          boolean(),
          keyword(),
          keyword()
        ) :: {EditorState.t(), [session_effect()]}
  defp recovery_effects(state, false, false, _swap_opts, _session_opts), do: {state, []}

  defp recovery_effects(state, swap_enabled?, session_enabled?, swap_opts, session_opts) do
    {state,
     [
       {:recover_session_async, swap_opts, session_opts, swap_enabled?, session_enabled?}
     ]}
  end

  @spec handle_save_session(EditorState.t()) :: {EditorState.t(), [session_effect()]}
  defp handle_save_session(state) do
    timer_effect =
      case state.frontend.backend do
        :headless -> {:cancel_session_timer}
        _backend -> {:restart_session_timer}
      end

    # Outside a project, or in an editor started on one file, this editor has no session to save.
    if persists_project?(state) do
      snapshot = Capture.snapshot(state)
      {state, [{:save_session_async, snapshot, project_session_opts(state)}, timer_effect]}
    else
      {state, [timer_effect]}
    end
  end
end
