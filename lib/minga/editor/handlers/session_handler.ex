defmodule Minga.Editor.Handlers.SessionHandler do
  @moduledoc """
  Pure handler for session persistence events.

  Extracts the `:check_swap_recovery` and `:save_session` clauses from
  the Editor GenServer into pure `{state, [effect]}` functions. Session
  I/O (disk reads, writes) and timer scheduling are expressed as effects.
  """

  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Session, as: SessionState
  alias Minga.Session

  @typedoc "Effects that the session handler may return."
  @type session_effect ::
          :render
          | {:log_message, String.t()}
          | {:save_session_async, Session.snapshot(), keyword()}
          | {:restart_session_timer}
          | {:cancel_session_timer}
          | {:recover_swap_entries, [Session.swap_entry()]}
          | {:restore_session, keyword()}

  @doc """
  Dispatches a session event to the appropriate handler.

  Returns `{state, effects}` where effects encode all side-effectful
  operations.
  """
  @spec handle(EditorState.t(), term()) :: {EditorState.t(), [session_effect()]}

  def handle(state, :check_swap_recovery) do
    handle_check_swap_recovery(state)
  end

  def handle(state, :save_session) do
    handle_save_session(state)
  end

  def handle(state, _msg) do
    {state, []}
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  @spec handle_check_swap_recovery(EditorState.t()) ::
          {EditorState.t(), [session_effect()]}
  defp handle_check_swap_recovery(state) do
    swap_ok? = SessionState.swap_enabled?(state.session)
    session_ok? = SessionState.enabled?(state.session)

    # Guard: swap recovery requires a swap_dir to be configured.
    # Session restoration requires a session_dir.
    handle_swap_and_session(state, swap_ok?, session_ok?)
  end

  @spec handle_swap_and_session(EditorState.t(), boolean(), boolean()) ::
          {EditorState.t(), [session_effect()]}
  defp handle_swap_and_session(state, false, false) do
    # Neither swap nor session configured — no-op.
    {state, []}
  end

  defp handle_swap_and_session(state, false, true) do
    # No swap dir — check if session needs restoration.
    if Session.clean_shutdown?(SessionState.session_opts(state.session)) do
      {state, []}
    else
      opts = SessionState.session_opts(state.session)
      {state, [{:restore_session, opts}]}
    end
  end

  defp handle_swap_and_session(state, true, session_ok?) do
    recoverable = Session.scan_recoverable_swaps(SessionState.swap_opts(state.session))

    case recoverable do
      [] ->
        if session_ok? and
             not Session.clean_shutdown?(SessionState.session_opts(state.session)) do
          opts = SessionState.session_opts(state.session)
          {state, [{:restore_session, opts}]}
        else
          {state, []}
        end

      entries ->
        {state, [{:recover_swap_entries, entries}]}
    end
  end

  @spec handle_save_session(EditorState.t()) :: {EditorState.t(), [session_effect()]}
  defp handle_save_session(state) do
    snapshot = Session.snapshot(state)
    opts = SessionState.session_opts(state.session)

    # Timer management: cancel existing and restart in non-headless mode
    timer_effect =
      if state.backend != :headless do
        [{:restart_session_timer}]
      else
        [{:cancel_session_timer}]
      end

    {state, [{:save_session_async, snapshot, opts} | timer_effect]}
  end
end
