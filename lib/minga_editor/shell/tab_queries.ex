defmodule MingaEditor.Shell.TabQueries do
  @moduledoc """
  Behaviour: tab and session queries that EditorState delegates to the
  active shell so it never pattern-matches on `tab_bar:` directly.

  Carved out of `MingaEditor.Shell`. Tab-less shells (a hypothetical
  Headless-with-UI shell, for instance) skip this contract entirely;
  callers should always go through `MingaEditor.State.AgentAccess` or
  `EditorState.active_tab/1` rather than calling these callbacks
  directly so the no-tabs case stays implicit.
  """

  @typedoc "Shell-specific state."
  @type shell_state :: term()

  @doc "Returns the currently active tab, or `nil` if the shell has no tabs."
  @callback active_tab(shell_state()) :: MingaEditor.State.Tab.t() | nil

  @doc """
  Finds the file tab whose snapshotted workspace has `pid` as active buffer.
  Returns `nil` if the shell has no tabs or no matching tab exists.
  """
  @callback find_tab_by_buffer(shell_state(), pid()) :: MingaEditor.State.Tab.t() | nil

  @doc """
  Returns the kind (`:file` or `:agent`) of the active tab. Shells
  without tabs return `:file` (the default content kind).
  """
  @callback active_tab_kind(shell_state()) :: atom()

  @doc """
  Associates a session pid with a tab. Returns updated shell state.
  No-op for shells without tabs.
  """
  @callback set_tab_session(shell_state(), tab_id :: term(), pid() | nil) :: shell_state()

  @doc """
  Returns the agent session pid for the user's current view. For
  Traditional this is the active tab's `:session`; for Board it's the
  zoomed card's `:session`. Returns `nil` when no session is in scope.

  This callback is the source of truth for "which agent session is the
  user looking at right now". `state.shell_state.agent` holds rendering
  caches populated from this pid; the pid itself lives on the tab/card.
  """
  @callback active_session(shell_state()) :: pid() | nil
end
