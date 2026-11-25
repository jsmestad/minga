defmodule MingaEditor.UI.Picker.Context do
  @moduledoc """
  Picker context struct — what picker sources need from MingaEditor.State.

  This struct decouples picker sources from the full `MingaEditor.State`, allowing
  sources to depend only on the subset of state they actually use. This makes
  sources easier to test, easier to reason about, and prevents the cyclic
  dependency between `UI.Picker` and `MingaEditor.State`.

  ## Fields

  - `buffers` — buffer list and active buffer (`MingaEditor.State.Buffers.t()`)
  - `editing` — vim state (marks, registers, jump positions, mode)
  - `file_tree` — file tree state (if available)
  - `search` — search state (buffer search, project search results)
  - `viewport` — viewport dimensions
  - `tab_bar` — tab bar state (tabs, active tab, workspaces)
  - `agent_session` — agent session PID (if available)
  - `live_agent` — live Agent presentation cache of the active workspace (if any)
  - `live_agent_ui` — live Agent UI state of the active workspace (if any)
  - `picker_ui` — picker UI state (context map for sources)
  - `document_symbols` — tree-sitter document symbols for the active window
  - `capabilities` — frontend capabilities (GUI detection, etc.)
  - `keymap_server` — keymap server used by this editor instance
  - `options_server` — options server used by this editor instance
  - `theme` — active theme
  """

  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.WorkspaceStatus
  alias MingaEditor.State
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.State.Search
  alias MingaEditor.State.TabBar
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.UI.Theme
  alias MingaEditor.State.FileTree

  @enforce_keys [
    :buffers,
    :editing,
    :search,
    :viewport,
    :tab_bar,
    :picker_ui,
    :capabilities,
    :theme
  ]

  defstruct [
    :buffers,
    :editing,
    :file_tree,
    :search,
    :viewport,
    :tab_bar,
    :agent_session,
    :live_agent,
    :live_agent_ui,
    :picker_ui,
    :capabilities,
    :keymap_server,
    :options_server,
    :theme,
    document_symbols: []
  ]

  @type t :: %__MODULE__{
          buffers: Buffers.t(),
          editing: VimState.t(),
          file_tree: FileTree.t() | nil,
          search: Search.t(),
          viewport: Viewport.t(),
          tab_bar: TabBar.t(),
          agent_session: pid() | nil,
          live_agent: AgentState.t() | nil,
          live_agent_ui: UIState.t() | nil,
          picker_ui: map(),
          document_symbols: [Minga.Language.Symbol.t()],
          capabilities: map(),
          keymap_server: State.keymap_server() | nil,
          options_server: State.options_server() | nil,
          theme: Theme.t()
        }

  # The project home holds no buffer of its own; the files of the tabs behind it are what can be switched to.
  @spec listed_buffers(State.t()) :: Buffers.t()
  defp listed_buffers(
         %State{
           workspace: %{launchpad: %MingaEditor.State.Launchpad{}, buffers: %Buffers{list: []}}
         } = state
       ),
       do: %Buffers{list: MingaEditor.Handlers.BufferRegistry.buffer_inventory(state)}

  defp listed_buffers(%State{workspace: %{buffers: buffers}}), do: buffers

  @doc """
  Builds a picker context from the full editor state.

  The optional `extra_context` is stored in `picker_ui.context` so that
  sources invoked from `PickerUI.open/3` can read it before the picker
  modal has been opened (i.e. when `shell_state.modal` is still `:none`).
  """
  @spec from_editor_state(State.t(), map() | nil) :: t()
  def from_editor_state(%State{} = state, extra_context \\ nil) do
    agent_session = MingaEditor.Shell.Runtime.active_session(state.shell_runtime)
    picker_ui = picker_ui_from_modal(state, extra_context)

    %__MODULE__{
      buffers: listed_buffers(state),
      editing: state.workspace.editing,
      file_tree: state.workspace.file_tree,
      search: state.workspace.search,
      viewport: state.frontend.terminal_viewport,
      tab_bar: state.shell_runtime.state.tab_bar,
      agent_session: agent_session,
      live_agent: WorkspaceStatus.live_agent(state.shell_runtime.state),
      live_agent_ui: state.workspace.agent_ui,
      picker_ui: picker_ui,
      document_symbols: active_document_symbols(state),
      capabilities: state.frontend.capabilities,
      keymap_server: state.interaction.keymap_server,
      options_server: state.interaction.options_server,
      theme: state.appearance.theme
    }
  end

  @doc "Returns a copy of the picker context with source-specific context data."
  @spec with_picker_context(t(), map() | nil) :: t()
  def with_picker_context(%__MODULE__{picker_ui: picker_ui} = ctx, context) do
    %{ctx | picker_ui: PickerState.put_context(picker_ui, context)}
  end

  @spec active_document_symbols(State.t()) :: [Minga.Language.Symbol.t()]
  defp active_document_symbols(%State{} = state) do
    case MingaEditor.Session.State.active_window_struct(state.workspace) do
      %{document_symbols: symbols} when is_list(symbols) -> symbols
      _ -> []
    end
  end

  @spec picker_ui_from_modal(State.t(), map() | nil) :: PickerState.t()
  defp picker_ui_from_modal(state, extra_context) do
    base =
      case state.shell_runtime.state.modal do
        {:picker, %{picker_ui: pui}} -> pui
        _ -> %PickerState{}
      end

    if extra_context, do: %{base | context: extra_context}, else: base
  end
end
