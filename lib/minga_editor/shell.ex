defmodule MingaEditor.Shell do
  @moduledoc """
  Behaviour for pluggable presentation shells.

  A shell owns layout, chrome, input routing, buffer lifecycle, and tab/session queries. The editor dispatches these presentation concerns to the active shell.
  """

  @typedoc "Shell-specific state. Each shell defines its own struct."
  @type shell_state :: term()

  @typedoc "Workspace state (the editing context shared by all shells)."
  @type workspace :: MingaEditor.Session.State.t()

  @typedoc "Structured GUI payload returned by a shell and encoded centrally by frontend protocol modules."
  @type gui_payload :: {atom(), term()} | nil

  @typedoc "Why a buffer was added."
  @type buffer_add_context :: :open | :preview

  @doc "Initializes shell state from config."
  @callback init(opts :: keyword()) :: shell_state()

  @doc "Returns a layout struct with named rectangles for each UI region."
  @callback compute_layout(editor_state :: term()) :: MingaEditor.Layout.t()

  @doc "Returns a chrome struct with draw lists for each UI region."
  @callback build_chrome(
              editor_state :: term(),
              layout :: MingaEditor.Layout.t(),
              scrolls :: map(),
              cursor_info :: term()
            ) :: MingaEditor.RenderPipeline.Chrome.t()

  @doc "Returns shell-specific data that affects chrome dirty tracking."
  @callback chrome_fingerprint(editor_state :: term()) :: term()

  @doc "Returns true when the shell can render through the asynchronous pipeline path."
  @callback async_render?(editor_state :: term()) :: boolean()

  @doc "Returns structured GUI payload data for the active shell, or nil."
  @callback gui_payload(editor_state :: term()) :: gui_payload() | nil

  @doc "Runs the full render pipeline and returns updated editor state."
  @callback render(editor_state :: term()) :: term()

  @doc "Returns the input handler stack for this shell."
  @callback input_handlers(editor_state :: term()) :: %{overlay: [module()], surface: [module()]}

  @doc "Handles a shell-specific event."
  @callback handle_event(shell_state(), workspace(), event :: term()) ::
              {shell_state(), workspace()}

  @doc "Handles a shell-specific GUI action from the native frontend."
  @callback handle_gui_action(shell_state(), workspace(), action :: term()) ::
              {shell_state(), workspace()}

  @doc "Runs after `handle_gui_action/3` has been applied to full editor state."
  @callback after_gui_action(editor_state :: term(), action :: term()) :: term()

  @doc "A buffer was added to the workspace."
  @callback on_buffer_added(
              shell_state(),
              prev_workspace :: workspace(),
              workspace(),
              buffer_pid :: pid(),
              context :: buffer_add_context()
            ) :: {shell_state(), workspace(), [MingaEditor.effect()]}

  @doc "The active buffer changed."
  @callback on_buffer_switched(shell_state(), workspace()) ::
              {shell_state(), workspace(), [MingaEditor.effect()]}

  @doc "A buffer process died."
  @callback on_buffer_died(shell_state(), workspace(), dead_pid :: pid()) ::
              {shell_state(), workspace(), [MingaEditor.effect()]}

  @doc "An agent session emitted a background event."
  @callback on_agent_event(shell_state(), workspace(), session_pid :: pid(), event :: term()) ::
              {shell_state(), workspace(), [MingaEditor.effect()]}

  @doc "Returns whether shell state owns an agent session pid."
  @callback owns_agent_session?(shell_state(), session_pid :: pid()) :: boolean()

  @doc "Handles an agent session going down and reports whether the shell owned it."
  @callback handle_agent_session_down(shell_state(), session_pid :: pid(), reason :: term()) ::
              {shell_state(), boolean()}

  @doc "A managed agent session restarted and the shell should refresh pid references."
  @callback handle_agent_session_restarted(
              shell_state(),
              old_session_pid :: pid(),
              new_session_pid :: pid(),
              reason :: term()
            ) :: {shell_state(), boolean()}

  @doc "Handles a remote session disconnect and reports whether the shell owned it."
  @callback handle_remote_session_disconnected(shell_state(), session_pid :: pid()) ::
              {shell_state(), boolean()}

  @doc "Persists shell state outside the pure Runtime transition boundary."
  @callback persist_shell_state(shell_state()) :: shell_state()

  @doc "Synchronizes optional agent status held by a shell."
  @callback sync_agent_status(shell_state(), session_pid :: pid(), status :: term()) ::
              shell_state()

  @doc "Tracks an agent-touched file in optional shell state."
  @callback track_agent_file(shell_state(), session_pid :: pid(), path :: String.t()) ::
              shell_state()

  @doc "Returns the currently active tab, or nil if the shell has no tabs."
  @callback active_tab(shell_state()) :: MingaEditor.State.Tab.t() | nil

  @doc "Finds the file tab whose snapshotted workspace has `pid` as active buffer."
  @callback find_tab_by_buffer(shell_state(), pid()) :: MingaEditor.State.Tab.t() | nil

  @doc "Returns the kind of the active tab."
  @callback active_tab_kind(shell_state()) :: atom()

  @doc "Associates a session pid with a tab."
  @callback set_tab_session(shell_state(), tab_id :: term(), pid() | nil) :: shell_state()

  @doc "Returns the agent session pid for the user's current view."
  @callback active_session(shell_state()) :: pid() | nil

  @optional_callbacks after_gui_action: 2,
                      owns_agent_session?: 2,
                      handle_agent_session_down: 3,
                      handle_agent_session_restarted: 4,
                      handle_remote_session_disconnected: 2,
                      persist_shell_state: 1,
                      sync_agent_status: 3,
                      track_agent_file: 3
end
