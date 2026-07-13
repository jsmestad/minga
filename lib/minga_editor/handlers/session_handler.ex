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

  defp apply_effect(state, {:restart_session_timer}),
    do: %{state | session: SessionState.restart_timer(state.session)}

  defp apply_effect(state, {:cancel_session_timer}),
    do: %{state | session: SessionState.cancel_timer(state.session)}

  defp apply_effect(
         state,
         {:recover_session_async, swap_opts, session_opts, swap_enabled?, session_enabled?}
       ) do
    Recovery.schedule(state, swap_opts, session_opts, swap_enabled?, session_enabled?)
  end

  @spec handle_check_swap_recovery(EditorState.t()) ::
          {EditorState.t(), [session_effect()]}
  defp handle_check_swap_recovery(%EditorState{backend: :headless} = state), do: {state, []}

  defp handle_check_swap_recovery(state) do
    swap_enabled? = SessionState.swap_enabled?(state.session)
    session_enabled? = SessionState.enabled?(state.session)

    recovery_effects(
      state,
      swap_enabled?,
      session_enabled?,
      SessionState.swap_opts(state.session),
      SessionState.session_opts(state.session)
    )
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
    snapshot = Session.snapshot(state)
    opts = SessionState.session_opts(state.session)

    timer_effect =
      case state.backend do
        :headless -> {:cancel_session_timer}
        _backend -> {:restart_session_timer}
      end

    {state, [{:save_session_async, snapshot, opts}, timer_effect]}
  end
end
