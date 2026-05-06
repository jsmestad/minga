defmodule MingaEditor.Shell.BufferLifecycle do
  @moduledoc """
  Behaviour: shell-side reactions to buffer and agent events.

  Carved out of `MingaEditor.Shell`. Callbacks receive shell state and workspace values, never full EditorState, so they cannot touch process monitors, render timers, or port managers. Generic concerns stay in EditorState.
  """

  @typedoc "Shell-specific state. Each shell defines its own struct."
  @type shell_state :: term()

  @typedoc "Workspace state."
  @type workspace :: MingaEditor.Workspace.State.t()

  @typedoc """
  Why a buffer was added. Shells use this to decide tab presentation.

  - `:open` — permanent open (file tree, `:e`, LSP jump, picker confirm).
    Creates a new tab or switches to an existing one.
  - `:preview` — transient picker preview. Updates the current tab
    in-place so navigating the picker doesn't spawn new tabs.
  """
  @type buffer_add_context :: :open | :preview

  @doc "A buffer was added to the workspace. Receives both the workspace before the buffer-pool mutation and the workspace after it, so shells can snapshot outgoing presentation state without capturing the newly activated buffer."
  @callback on_buffer_added(
              shell_state(),
              prev_workspace :: workspace(),
              workspace(),
              buffer_pid :: pid(),
              context :: buffer_add_context()
            ) :: {shell_state(), workspace()}

  @doc "The active buffer changed."
  @callback on_buffer_switched(shell_state(), workspace()) ::
              {shell_state(), workspace()}

  @doc "A buffer process died."
  @callback on_buffer_died(shell_state(), workspace(), dead_pid :: pid()) ::
              {shell_state(), workspace()}

  @doc """
  An agent session emitted an event. The shell reflects the status
  change in its chrome (tab badges, card status icons, attention flags).
  Foreground/background routing happens in `MingaEditor.handle_info/2`;
  this callback receives only background events.
  """
  @callback on_agent_event(
              shell_state(),
              workspace(),
              session_pid :: pid(),
              event :: term()
            ) :: {shell_state(), workspace()}
end
