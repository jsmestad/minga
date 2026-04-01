defmodule MingaEditor.Agent.ViewContext do
  @moduledoc """
  Agent view rendering context.

  Contains the subset of `MingaEditor.State` that agent renderers need to
  draw the prompt input, dashboard sidebar, and agent chat chrome.
  Decouples `lib/minga/agent/view/` modules from `MingaEditor.State`
  dependencies (per ticket #1224).

  Both `PromptRenderer` and `DashboardRenderer` consume this struct.
  Constructed via `from_editor_state/1` at the call sites in the
  render pipeline.
  """

  alias MingaEditor.Agent.UIState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.VimState
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.UI.Theme

  @enforce_keys [:ui_state, :capabilities, :theme, :editing]
  defstruct [
    :session,
    :ui_state,
    :capabilities,
    :theme,
    :layout_rect,
    :editing,
    :buffers,
    :agent_status,
    :pending_approval
  ]

  @typedoc "Agent view rendering context."
  @type t :: %__MODULE__{
          session: pid() | nil,
          ui_state: UIState.t(),
          capabilities: Capabilities.t(),
          theme: Theme.t(),
          layout_rect: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()} | nil,
          editing: VimState.t(),
          buffers: MingaEditor.State.Buffers.t(),
          agent_status: atom() | nil,
          pending_approval: map() | nil
        }

  @typedoc "Screen rectangle {row, col, width, height}."
  @type rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  @doc """
  Builds a `ViewContext` from full editor state.

  Extracts only the fields agent renderers need, eliminating the
  `MingaEditor.State` dependency from agent view modules.
  """
  @spec from_editor_state(EditorState.t()) :: t()
  def from_editor_state(%EditorState{} = state) do
    agent = AgentAccess.agent(state)

    %__MODULE__{
      session: AgentAccess.session(state),
      ui_state: state.workspace.agent_ui,
      capabilities: state.capabilities,
      theme: state.theme,
      layout_rect: nil,
      editing: state.workspace.editing,
      buffers: state.workspace.buffers,
      agent_status: agent.status,
      pending_approval: agent.pending_approval
    }
  end
end
