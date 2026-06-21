defmodule MingaEditor.Collab.Cleanup do
  @moduledoc """
  Per-session teardown for collab editor sessions.

  Called by `MingaEditor.Collab.SessionManager.stop_session/1` just before a
  session's triad is terminated. Frees the session-scoped state that does *not*
  die automatically when the editor/renderer/frontend processes stop.

  Most per-session UI state already lives inside the editor's
  `MingaEditor.Session.State` (windows, cursor, mode, feature state) and dies
  with the editor process, so OTP reclaims it for free. This module is the seam
  for cleaning up the rest:

  - Per-session `persistent_term` notify targets used by the sidebar and
    semantic-ui registries to route render triggers back to a session.

  Node-shared registries (the default sidebar/semantic-ui tables, the buffer
  registry, the parser) are deliberately left untouched: other sessions and the
  default editor still depend on them.
  """

  alias MingaEditor.Collab.Names

  @doc """
  Cleans up session-scoped state for `session_id`.

  Idempotent and crash-safe: never raises, returns `:ok`. Refuses to touch the
  default session (its state is owned by the static supervision tree).
  """
  @spec cleanup(Names.session_id()) :: :ok
  def cleanup(session_id) when is_binary(session_id) do
    if Names.default_session?(session_id) do
      :ok
    else
      clear_notify_targets(session_id)
      :ok
    end
  rescue
    error ->
      Minga.Log.debug(
        :editor,
        "collab session cleanup skipped for #{session_id}: #{inspect(error)}"
      )

      :ok
  end

  # Per-session sidebar/semantic-ui tables (when a session opts into its own
  # tables) register a persistent_term notify target keyed by the table name.
  # A session's table name is its editor via-tuple's session id, so we erase any
  # notify target keyed under this session's per-table names. This is a no-op for
  # sessions that share the default node tables, which is the MVP default.
  @spec clear_notify_targets(Names.session_id()) :: :ok
  defp clear_notify_targets(session_id) do
    Enum.each(notify_keys(session_id), fn key ->
      :persistent_term.erase(key)
    end)

    :ok
  end

  @spec notify_keys(Names.session_id()) :: [term()]
  defp notify_keys(session_id) do
    table = session_table_name(session_id)

    [
      {MingaEditor.Extension.Sidebar, table, :notify},
      {MingaEditor.Agent.SemanticUI.Registry, table, :notify}
    ]
  end

  # Per-session-table naming convention (collab MVP, #2424).
  #
  # This is the single source of truth for the per-session table name. The
  # producer side is `MingaEditor.Startup.register_sidebar_contributions/2`,
  # which today registers contributions under the *default* node table, so the
  # notify targets cleared above do not exist yet and `cleanup/1` is a no-op.
  #
  # When per-session tables land, `Startup` must register a non-default session's
  # contributions under exactly this name so the persistent_term notify keys
  # cleared in `clear_notify_targets/1` line up with what was registered. Keep
  # this name and the `Startup` producer in sync; see the matching note there.
  @spec session_table_name(Names.session_id()) :: atom()
  defp session_table_name(session_id) do
    :"collab_session_#{session_id}"
  end
end
