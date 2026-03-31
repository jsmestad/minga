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
  - `tab_bar` — tab bar state (tabs, active tab, agent groups)
  - `agent_session` — agent session PID (if available)
  - `picker_ui` — picker UI state (context map for sources)
  - `capabilities` — frontend capabilities (GUI detection, etc.)
  - `theme` — active theme
  """

  alias MingaEditor.State
  alias MingaEditor.State.Buffers
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
    :picker_ui,
    :capabilities,
    :theme
  ]

  @type t :: %__MODULE__{
          buffers: Buffers.t(),
          editing: VimState.t(),
          file_tree: FileTree.t() | nil,
          search: Search.t(),
          viewport: Viewport.t(),
          tab_bar: TabBar.t(),
          agent_session: pid() | nil,
          picker_ui: map(),
          capabilities: map(),
          theme: Theme.t()
        }

  @doc """
  Builds a picker context from the full editor state.
  """
  @spec from_editor_state(State.t()) :: t()
  def from_editor_state(%State{} = state) do
    agent_session = state.shell_state.agent.session

    %__MODULE__{
      buffers: state.workspace.buffers,
      editing: state.workspace.editing,
      file_tree: Map.get(state.workspace, :file_tree),
      search: state.workspace.search,
      viewport: state.workspace.viewport,
      tab_bar: state.shell_state.tab_bar,
      agent_session: agent_session,
      picker_ui: state.shell_state.picker_ui,
      capabilities: state.capabilities,
      theme: state.theme
    }
  end
end
