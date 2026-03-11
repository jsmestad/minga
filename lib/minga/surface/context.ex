defmodule Minga.Surface.Context do
  @moduledoc """
  Shared state passed to surfaces on each operation.

  Surfaces don't own shared infrastructure like the theme, port manager,
  or terminal capabilities. Instead, the Editor builds a Context struct
  before calling surface callbacks and passes it in via the surface's
  state. This keeps the Surface behaviour's callback signatures clean
  (only `state` and operation-specific args) while giving surfaces
  access to everything they need.

  During Phase 1, the context is populated by the bridge layer and
  stored as a field on `BufferView.State`. In later phases, surfaces
  may receive context through a different mechanism (e.g., a separate
  callback parameter or process dictionary).
  """

  alias Minga.Editor.State, as: EditorState
  alias Minga.Port.Capabilities
  alias Minga.Theme

  @type t :: %__MODULE__{
          port_manager: GenServer.server() | nil,
          theme: Theme.t(),
          capabilities: Capabilities.t(),
          status_msg: String.t() | nil,
          focus_stack: [module()],
          keymap_scope: atom(),
          layout: term(),
          tab_bar: term(),
          render_timer: reference() | nil,
          picker_ui: term(),
          whichkey: term(),
          modeline_click_regions: list(),
          tab_bar_click_regions: list(),
          agent: term(),
          agentic: term()
        }

  @enforce_keys [:theme]
  defstruct port_manager: nil,
            theme: nil,
            capabilities: %Capabilities{},
            status_msg: nil,
            focus_stack: [],
            keymap_scope: :editor,
            layout: nil,
            tab_bar: nil,
            render_timer: nil,
            picker_ui: nil,
            whichkey: nil,
            modeline_click_regions: [],
            tab_bar_click_regions: [],
            agent: nil,
            agentic: nil

  @doc """
  Extracts a context from the current EditorState.

  Copies shared fields that surfaces need but don't own.
  """
  @spec from_editor_state(EditorState.t()) :: t()
  def from_editor_state(%EditorState{} = es) do
    %__MODULE__{
      port_manager: es.port_manager,
      theme: es.theme,
      capabilities: es.capabilities,
      status_msg: es.status_msg,
      focus_stack: es.focus_stack,
      keymap_scope: es.keymap_scope,
      layout: es.layout,
      tab_bar: es.tab_bar,
      render_timer: es.render_timer,
      picker_ui: es.picker_ui,
      whichkey: es.whichkey,
      modeline_click_regions: es.modeline_click_regions,
      tab_bar_click_regions: es.tab_bar_click_regions,
      # Agent state is carried in context during Phase 1 so that
      # Input.Scoped's agent-panel branches work correctly when
      # the surface reconstructs an EditorState for dispatch.
      agent: es.agent,
      agentic: es.agentic
    }
  end

  @doc """
  Writes context fields that may have been modified back to EditorState.

  Only a few context fields can change during a surface operation
  (e.g., layout cache, click regions). Most are read-only.
  """
  @spec to_editor_state(EditorState.t(), t()) :: EditorState.t()
  def to_editor_state(%EditorState{} = es, %__MODULE__{} = ctx) do
    %{
      es
      | layout: ctx.layout,
        modeline_click_regions: ctx.modeline_click_regions,
        tab_bar_click_regions: ctx.tab_bar_click_regions
    }
  end
end
