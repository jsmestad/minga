defmodule MingaEditor.Shell do
  @moduledoc """
  Umbrella behaviour for pluggable presentation shells.

  A shell owns layout, chrome, input routing, buffer lifecycle, and
  tab queries. Each responsibility is a focused sub-behaviour:

  - `MingaEditor.Shell.Layout` - `compute_layout/1`
  - `MingaEditor.Shell.Chrome` - `build_chrome/4`, `async_render?/1`, `render/1`
  - `MingaEditor.Shell.InputRouter` - `input_handlers/1`,
    `handle_event/3`, `handle_gui_action/3`
  - `MingaEditor.Shell.BufferLifecycle` - `on_buffer_added/5`,
    `on_buffer_switched/2`, `on_buffer_died/3`, `on_agent_event/4`
  - `MingaEditor.Shell.TabQueries` - `active_tab/1`,
    `find_tab_by_buffer/2`, `active_tab_kind/1`, `set_tab_session/3`,
    `active_session/1`

  This umbrella declares only `init/1` (the constructor every shell needs); all other callbacks live on their respective sub-behaviours. Registry-loaded shells currently must implement the full presentation contract above because the editor still dispatches through each surface. Tab-less shells should return safe defaults from the tab query callbacks until the registry grows capability-aware validation.

  ## Implementation

  Implement `init/1` plus the sub-behaviours your shell needs, then
  set the module as the `:shell` field on `MingaEditor.State`. The
  Editor GenServer dispatches to the active shell for presentation
  concerns.

  ## Available shells

  - `MingaEditor.Shell.Traditional` — tab-based editor with file tree,
    modeline, picker, and agent panel. The default shell.
  - Bundled or third-party extension shells registered through `MingaEditor.Shell.Registry`.
  """

  @typedoc "Shell-specific state. Each shell defines its own struct."
  @type shell_state :: term()

  @typedoc "Workspace state (the editing context shared by all shells)."
  @type workspace :: MingaEditor.Session.State.t()

  @typedoc "Structured GUI payload returned by a shell and encoded centrally by frontend protocol modules. Unknown tags are treated as unsupported extension payloads and logged by the GUI emitter."
  @type gui_payload ::
          {:board, MingaEditor.Frontend.Protocol.GUI.BoardPayload.t()} | {atom(), term()} | nil

  @typedoc """
  Why a buffer was added — re-exported here from `Shell.BufferLifecycle`
  so existing call sites that use `MingaEditor.Shell.buffer_add_context/0`
  keep compiling.
  """
  @type buffer_add_context :: MingaEditor.Shell.BufferLifecycle.buffer_add_context()

  @doc """
  Initialize shell state from config. Called once during Editor startup.
  Returns the shell's initial state.
  """
  @callback init(opts :: keyword()) :: shell_state()
end
