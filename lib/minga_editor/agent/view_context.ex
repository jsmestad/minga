defmodule MingaEditor.Agent.ViewContext do
  @moduledoc """
  Agent view rendering context.

  Contains the subset of `MingaEditor.State` that the agent prompt geometry
  (`PromptRenderer`) and the semantic prompt model (`PromptRenderWindow`)
  need. Decouples `lib/minga_editor/agent/view/` modules from
  `MingaEditor.State` dependencies (per ticket #1224).

  Constructed via `from_editor_state/1` at the call sites in the
  render pipeline.
  """

  alias MingaEditor.Agent.UIState
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.State, as: EditorState
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
    :active_tool_name,
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
          active_tool_name: String.t() | nil,
          pending_approval: map() | nil
        }

  @typedoc "Screen rectangle {row, col, width, height}."
  @type rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  @doc """
  Builds a `ViewContext` from full editor state.

  Extracts only the fields agent renderers need, eliminating the
  `MingaEditor.State` dependency from agent view modules.
  """
  @spec from_editor_state(EditorState.t() | map()) :: t()
  def from_editor_state(%EditorState{} = state) do
    build_context(state)
  end

  def from_editor_state(%Input{} = input) do
    build_pipeline_context(input)
  end

  def from_editor_state(%{workspace: %{agent_ui: _}} = state) do
    build_context(state)
  end

  @spec build_context(map()) :: t()
  defp build_context(state) do
    agent = MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)

    %__MODULE__{
      session: MingaEditor.Shell.Runtime.active_session(state.shell_runtime),
      ui_state: state.workspace.agent_ui,
      capabilities: state.frontend.capabilities,
      theme: state.appearance.theme,
      layout_rect: nil,
      editing: state.workspace.editing,
      buffers: state.workspace.buffers,
      agent_status: agent.runtime.status,
      active_tool_name: agent.runtime.active_tool_name,
      pending_approval: agent.pending_approval
    }
  end

  @spec build_pipeline_context(Input.t()) :: t()
  defp build_pipeline_context(input) do
    agent = MingaEditor.Shell.Traditional.State.agent(input.shell_state)

    %__MODULE__{
      session: input.shell.active_session(input.shell_state),
      ui_state: input.workspace.agent_ui,
      capabilities: input.capabilities,
      theme: input.theme,
      layout_rect: nil,
      editing: input.workspace.editing,
      buffers: input.workspace.buffers,
      agent_status: agent.runtime.status,
      active_tool_name: agent.runtime.active_tool_name,
      pending_approval: agent.pending_approval
    }
  end
end
