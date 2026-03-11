defmodule Minga.Surface.AgentView do
  @moduledoc """
  Surface implementation for the AI agent chat view.

  Owns the agent session lifecycle, chat scroll, panel state (input,
  vim, history), preview pane, search state, toast queue, diff
  baselines, pending approval, and spinner. This is the surface for
  agent tabs and the agentic full-screen view.

  ## Phase 2 design

  Like BufferView in Phase 1, AgentView acts as a facade over the
  existing input and rendering infrastructure. The heavy lifting
  still happens in `Input.Scoped` (agent branches), `Commands.Agent`,
  and `RenderPipeline.run_agentic`. AgentView's job is to own the
  state boundary: it holds an `AgentView.State` struct and converts
  to/from `EditorState` via the bridge layer.
  """

  @behaviour Minga.Surface

  alias Minga.Editor.Layout
  alias Minga.Editor.RenderPipeline
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.Viewport
  alias Minga.Mode
  alias Minga.Surface.AgentView.Bridge
  alias Minga.Surface.AgentView.State, as: AVState
  alias Minga.Surface.Context

  # ── Surface callbacks ──────────────────────────────────────────────────────

  @impl Minga.Surface
  @spec scope() :: :agent
  def scope, do: :agent

  @doc """
  Processes a key press for the agent view.

  Walks the surface-level handlers (Scoped, GlobalBindings, ModeFSM)
  on a reconstructed EditorState. Overlays (picker, completion,
  conflict prompt) have already been checked by the Editor before
  this callback is reached.

  During Phase 2, the Router calls surface handlers on EditorState
  directly (via the bridge reconstruction) to preserve all side
  effects. This is the same approach used in BufferView Phase 1.
  """
  @impl Minga.Surface
  @spec handle_key(AVState.t(), non_neg_integer(), non_neg_integer()) ::
          {AVState.t(), [Minga.Surface.effect()]}
  def handle_key(%AVState{context: nil} = av_state, _codepoint, _modifiers) do
    {av_state, []}
  end

  def handle_key(%AVState{} = av_state, codepoint, modifiers) do
    editor_state = reconstruct_editor_state(av_state)

    new_editor_state =
      Enum.reduce_while(Minga.Input.surface_handlers(), editor_state, fn handler, acc ->
        case handler.handle_key(acc, codepoint, modifiers) do
          {:handled, new_state} -> {:halt, new_state}
          {:passthrough, new_state} -> {:cont, new_state}
        end
      end)

    new_av_state = Bridge.from_editor_state(new_editor_state)
    {new_av_state, []}
  end

  @doc """
  Processes a mouse event for the agent view.

  Routes to `Agent.View.Mouse` via the surface handler walk.
  """
  @impl Minga.Surface
  @spec handle_mouse(
          AVState.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: {AVState.t(), [Minga.Surface.effect()]}
  def handle_mouse(%AVState{context: nil} = av_state, _row, _col, _button, _mods, _et, _cc) do
    {av_state, []}
  end

  def handle_mouse(%AVState{} = av_state, row, col, button, mods, event_type, click_count) do
    editor_state = reconstruct_editor_state(av_state)

    new_editor_state =
      walk_mouse_handlers(editor_state, row, col, button, mods, event_type, click_count)

    new_av_state = Bridge.from_editor_state(new_editor_state)
    {new_av_state, []}
  end

  @doc """
  Renders the agent view.

  Reconstructs an EditorState and delegates to `RenderPipeline.run_agentic_pipeline/2`.
  During Phase 2 the pipeline emits directly to the port, so the
  returned draw list is empty.
  """
  @impl Minga.Surface
  @spec render(AVState.t(), {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}) ::
          {AVState.t(), [Minga.Editor.DisplayList.draw()]}
  def render(%AVState{context: nil} = av_state, _rect) do
    {av_state, []}
  end

  def render(%AVState{} = av_state, _rect) do
    editor_state = reconstruct_editor_state(av_state)

    editor_state = RenderPipeline.compute_layout(editor_state)
    layout = Layout.get(editor_state)

    new_editor_state = RenderPipeline.run_agentic_pipeline(editor_state, layout)
    new_av_state = Bridge.from_editor_state(new_editor_state)
    {new_av_state, []}
  end

  @doc """
  Handles domain-specific events for the agent view.

  Events include agent_event messages (status_changed, text_delta,
  tool_started, etc.). During Phase 2, these are still handled by
  `Editor.handle_info` clauses and the bridge syncs the state
  changes back to the surface.
  """
  @impl Minga.Surface
  @spec handle_event(AVState.t(), term()) :: {AVState.t(), [Minga.Surface.effect()]}
  def handle_event(%AVState{} = av_state, _event) do
    {av_state, []}
  end

  @doc """
  Returns the cursor position and shape for the agent view.

  When input is focused, returns the input cursor position with a beam
  shape. Otherwise returns a hidden cursor at (0, 0).
  """
  @impl Minga.Surface
  @spec cursor(AVState.t()) :: {non_neg_integer(), non_neg_integer(), atom()}
  def cursor(%AVState{agent: %{panel: %{input_focused: true, input: input}}}) do
    {row, col} = input.cursor
    {row, col, :beam}
  end

  def cursor(%AVState{}) do
    {0, 0, :hidden}
  end

  @doc """
  Called when this surface becomes the active tab.
  """
  @impl Minga.Surface
  @spec activate(AVState.t()) :: AVState.t()
  def activate(%AVState{} = av_state) do
    %{av_state | agentic: %{av_state.agentic | active: true}}
  end

  @doc """
  Called when this surface is backgrounded (another tab activated).
  """
  @impl Minga.Surface
  @spec deactivate(AVState.t()) :: AVState.t()
  def deactivate(%AVState{} = av_state) do
    %{av_state | agentic: %{av_state.agentic | active: false}}
  end

  # ── Bridge helpers ─────────────────────────────────────────────────────────

  @spec from_editor_state(EditorState.t()) :: AVState.t()
  defdelegate from_editor_state(editor_state), to: Bridge

  @spec to_editor_state(EditorState.t(), AVState.t()) :: EditorState.t()
  defdelegate to_editor_state(editor_state, av_state), to: Bridge

  # ── Private ────────────────────────────────────────────────────────────────

  @spec walk_mouse_handlers(
          EditorState.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) ::
          EditorState.t()
  defp walk_mouse_handlers(state, row, col, button, mods, event_type, click_count) do
    Enum.reduce_while(Minga.Input.surface_handlers(), state, fn handler, acc ->
      dispatch_mouse_to_handler(handler, acc, row, col, button, mods, event_type, click_count)
    end)
  end

  @spec dispatch_mouse_to_handler(
          module(),
          EditorState.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: {:halt, EditorState.t()} | {:cont, EditorState.t()}
  defp dispatch_mouse_to_handler(handler, state, row, col, button, mods, event_type, cc) do
    Code.ensure_loaded(handler)

    if function_exported?(handler, :handle_mouse, 7) do
      case handler.handle_mouse(state, row, col, button, mods, event_type, cc) do
        {:handled, new_state} -> {:halt, new_state}
        {:passthrough, new_state} -> {:cont, new_state}
      end
    else
      {:cont, state}
    end
  end

  # Builds an EditorState from the AgentView state and its shared context.
  # Phase 2 scaffolding: the input handlers and render pipeline operate on
  # EditorState, so we reconstruct one for delegation.
  @spec reconstruct_editor_state(AVState.t()) :: EditorState.t()
  defp reconstruct_editor_state(%AVState{context: %Context{} = ctx} = av) do
    %EditorState{
      # Agent-view owned fields
      agent: av.agent,
      agentic: av.agentic,
      # Shared context fields
      port_manager: ctx.port_manager,
      theme: ctx.theme,
      capabilities: ctx.capabilities,
      status_msg: ctx.status_msg,
      focus_stack: ctx.focus_stack,
      keymap_scope: ctx.keymap_scope,
      layout: ctx.layout,
      tab_bar: ctx.tab_bar,
      render_timer: ctx.render_timer,
      picker_ui: ctx.picker_ui,
      whichkey: ctx.whichkey,
      modeline_click_regions: ctx.modeline_click_regions,
      tab_bar_click_regions: ctx.tab_bar_click_regions,
      # Buffer fields from context (agent needs active buffer for some commands)
      buffers: ctx.buffers || %Buffers{},
      viewport: ctx.viewport || Viewport.new(24, 80),
      # Vim state from context (agent uses mode FSM for prompt editing)
      mode: ctx.mode || :normal,
      mode_state: ctx.mode_state || Mode.initial_state()
    }
  end
end
