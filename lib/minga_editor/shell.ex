defmodule MingaEditor.Shell do
  @moduledoc """
  Behaviour for pluggable presentation shells.

  A shell owns layout, chrome, input routing, and rendering for a
  specific UX model. The traditional editor, The Board, and headless
  mode are all shells. The workspace (core editing state) is shared;
  the shell decides how to present it.

  ## Implementation

  Implement all callbacks in a module and set it as the `:shell` field
  on `MingaEditor.State`. The Editor GenServer dispatches to the active
  shell for presentation concerns.

  ## Available shells

  - `MingaEditor.Shell.Traditional` — tab-based editor with file tree, modeline,
    picker, and agent panel. The default shell and the only one today.
  """

  @typedoc "Shell-specific state. Each shell defines its own struct."
  @type shell_state :: term()

  @typedoc "Workspace state (the editing context shared by all shells)."
  @type workspace :: MingaEditor.Workspace.State.t()

  @doc """
  Initialize shell state from config and initial workspace.

  Called once during Editor startup. Returns the shell's initial state.
  """
  @callback init(opts :: keyword()) :: shell_state()

  @doc """
  Handle a shell-specific event (tool prompt, nav flash, git status, etc.).

  Returns the updated shell state and workspace. The Editor GenServer
  calls this for events that are presentation concerns, not core editing.
  """
  @callback handle_event(shell_state(), workspace(), event :: term()) ::
              {shell_state(), workspace()}

  @doc """
  Handle a shell-specific GUI action from the native frontend.

  Returns the updated shell state and workspace.
  """
  @callback handle_gui_action(shell_state(), workspace(), action :: term()) ::
              {shell_state(), workspace()}

  @doc """
  Returns the input handler stack for this shell.

  Overlay handlers (picker, completion, conflict prompt) sit above
  the surface and intercept keys first. Surface handlers (dashboard,
  file tree, agent panel, mode dispatch) handle keys when no overlay
  claims them. The Editor walks overlays first, then surfaces.
  """
  @callback input_handlers(editor_state :: term()) :: %{overlay: [module()], surface: [module()]}

  @doc """
  Compute spatial layout for the current state.

  Returns a layout struct with named rectangles for each UI region.
  The shell decides what regions exist (tab bar, modeline, file tree,
  editor panes, agent panel, bottom panel, etc.).
  """
  @callback compute_layout(editor_state :: term()) :: MingaEditor.Layout.t()

  @doc """
  Build chrome (tab bar, modeline, file tree, overlays, etc.).

  Returns a chrome struct with draw lists for each UI region. The
  shell decides which chrome elements exist and how they render.
  """
  @callback build_chrome(
              editor_state :: term(),
              layout :: MingaEditor.Layout.t(),
              scrolls :: map(),
              cursor_info :: term()
            ) :: MingaEditor.RenderPipeline.Chrome.t()

  @doc """
  Render a complete frame.

  Runs the full render pipeline (content, chrome, compose, emit) and
  sends commands to the frontend. Returns updated state with cached
  render data.
  """
  @callback render(editor_state :: term()) :: term()

  # -------------------------------------------------------------------
  # Buffer lifecycle callbacks
  #
  # The Editor GenServer calls these when buffers are added, switched,
  # or die. Each shell decides how to present the change (e.g.,
  # Traditional manages tab bar state, Board ignores or routes to cards).
  #
  # Callbacks receive (shell_state, workspace, ...) — never full
  # EditorState — so they cannot touch process monitors, render timers,
  # or port managers. Generic concerns stay in EditorState.
  # -------------------------------------------------------------------

  @typedoc """
  Why a buffer was added. Shells use this to decide tab presentation.

  - `:open` — permanent open (file tree, `:e`, LSP jump, picker confirm).
    Creates a new tab or switches to an existing one.
  - `:preview` — transient picker preview. Updates the current tab
    in-place so navigating the picker doesn't spawn new tabs.
  """
  @type buffer_add_context :: :open | :preview

  @doc """
  A buffer was added to the workspace.

  Called after the buffer pid is in `workspace.buffers` and monitored.
  The shell decides how to present it (e.g., create/update tabs, route
  to a card, or ignore). `context` tells the shell WHY the buffer was
  added so it can choose the right presentation strategy.
  """
  @callback on_buffer_added(
              shell_state(),
              workspace(),
              buffer_pid :: pid(),
              context :: buffer_add_context()
            ) ::
              {shell_state(), workspace()}

  @doc """
  The active buffer changed.

  Called after `workspace.buffers.active` has been updated. The shell
  decides whether to sync the active window, update chrome, etc.
  """
  @callback on_buffer_switched(shell_state(), workspace()) ::
              {shell_state(), workspace()}

  @doc """
  A buffer process died.

  Called after the dead buffer has been removed from `workspace.buffers`.
  The shell cleans up any references (tab entries, card associations, etc.).
  """
  @callback on_buffer_died(shell_state(), workspace(), dead_pid :: pid()) ::
              {shell_state(), workspace()}

  # -------------------------------------------------------------------
  # Agent event callbacks
  #
  # Called by the Editor GenServer when an agent session emits an event
  # for a background tab/card (not the active one). Each shell decides
  # how to reflect the status change in its chrome (tab badges, card
  # status icons, etc.).
  # -------------------------------------------------------------------

  @doc """
  A background agent session emitted an event.

  Called when `session_pid` is not the active session. The shell updates
  its presentation state (tab badges, card status, attention flags, etc.).
  """
  @callback on_agent_event(
              shell_state(),
              workspace(),
              session_pid :: pid(),
              event :: term()
            ) :: {shell_state(), workspace()}

  # -------------------------------------------------------------------
  # Tab query/mutation delegates
  #
  # EditorState delegates these to the active shell so it never
  # pattern-matches on `tab_bar:` directly. Traditional implements
  # with TabBar lookups; Board returns static defaults.
  # -------------------------------------------------------------------

  @doc """
  Returns the currently active tab, or `nil` if the shell has no tabs.
  """
  @callback active_tab(shell_state()) :: MingaEditor.State.Tab.t() | nil

  @doc """
  Finds the file tab whose snapshotted workspace has `pid` as active buffer.

  Returns `nil` if the shell has no tabs or no matching tab exists.
  """
  @callback find_tab_by_buffer(shell_state(), pid()) :: MingaEditor.State.Tab.t() | nil

  @doc """
  Returns the kind (`:file` or `:agent`) of the active tab.

  Shells without tabs return `:file` (the default content kind).
  """
  @callback active_tab_kind(shell_state()) :: atom()

  @doc """
  Associates a session pid with a tab. Returns updated shell state.

  No-op for shells without tabs.
  """
  @callback set_tab_session(shell_state(), tab_id :: term(), pid() | nil) :: shell_state()
end
