defmodule Minga.Shell do
  @moduledoc """
  Behaviour for pluggable presentation shells.

  A shell owns layout, chrome, input routing, and rendering for a
  specific UX model. The traditional editor, The Board, and headless
  mode are all shells. The workspace (core editing state) is shared;
  the shell decides how to present it.

  ## Implementation

  Implement all callbacks in a module and set it as the `:shell` field
  on `Minga.Editor.State`. The Editor GenServer dispatches to the active
  shell for presentation concerns.

  ## Available shells

  - `Minga.Shell.Traditional` — tab-based editor with file tree, modeline,
    picker, and agent panel. The default shell and the only one today.
  """

  @typedoc "Shell-specific state. Each shell defines its own struct."
  @type shell_state :: term()

  @typedoc "Workspace state (the editing context shared by all shells)."
  @type workspace :: Minga.Workspace.State.t()

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
  @callback input_handlers(shell_state()) :: %{overlay: [module()], surface: [module()]}

  @doc """
  Compute spatial layout for the current state.

  Returns a layout struct with named rectangles for each UI region.
  The shell decides what regions exist (tab bar, modeline, file tree,
  editor panes, agent panel, bottom panel, etc.).
  """
  @callback compute_layout(editor_state :: term()) :: Minga.Editor.Layout.t()

  @doc """
  Build chrome (tab bar, modeline, file tree, overlays, etc.).

  Returns a chrome struct with draw lists for each UI region. The
  shell decides which chrome elements exist and how they render.
  """
  @callback build_chrome(
              editor_state :: term(),
              layout :: Minga.Editor.Layout.t(),
              scrolls :: map(),
              cursor_info :: term()
            ) :: Minga.Editor.RenderPipeline.Chrome.t()

  @doc """
  Render a complete frame.

  Runs the full render pipeline (content, chrome, compose, emit) and
  sends commands to the frontend. Returns updated state with cached
  render data.
  """
  @callback render(editor_state :: term()) :: term()
end
