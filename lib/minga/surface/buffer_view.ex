defmodule Minga.Surface.BufferView do
  @moduledoc """
  Surface implementation for file editing.

  Owns the buffer list, window tree, file tree, viewport, vim editing
  model, and the `run_windows` render path. This is the default surface
  for file tabs and the editor's primary view.

  ## Phase 1 design

  During the initial Surface extraction, BufferView acts as a facade
  over the existing input and rendering infrastructure. The heavy
  lifting still happens in `Input.Scoped`, `Input.ModeFSM`,
  `RenderPipeline`, and the command modules. BufferView's job is to
  own the state boundary: it holds a `BufferView.State` struct and
  converts to/from `EditorState` via the bridge layer.

  This facade pattern lets us migrate incrementally. Each subsequent
  phase moves more logic into the surface and shrinks the bridge.
  """

  @behaviour Minga.Surface

  alias Minga.Editor.Layout
  alias Minga.Editor.RenderPipeline
  alias Minga.Editor.State, as: EditorState
  alias Minga.Surface.BufferView.Bridge
  alias Minga.Surface.BufferView.State, as: BufferViewState
  alias Minga.Surface.Context

  # ── Surface callbacks ──────────────────────────────────────────────────────

  @impl Minga.Surface
  @spec scope() :: :editor
  def scope, do: :editor

  @doc """
  Processes a key press for the buffer view.

  Walks the surface-level handlers (Scoped, GlobalBindings, ModeFSM)
  on a reconstructed EditorState. Overlays (picker, completion,
  conflict prompt) have already been checked by the Editor before
  this callback is reached.

  During Phase 1, the Router calls surface handlers on EditorState
  directly (not through this callback) to preserve all side effects.
  This callback is available for standalone use and testing. In later
  phases it becomes the primary entry point.
  """
  @impl Minga.Surface
  @spec handle_key(BufferViewState.t(), non_neg_integer(), non_neg_integer()) ::
          {BufferViewState.t(), [Minga.Surface.effect()]}
  def handle_key(%BufferViewState{context: nil} = bv_state, _codepoint, _modifiers) do
    {bv_state, []}
  end

  def handle_key(%BufferViewState{} = bv_state, codepoint, modifiers) do
    editor_state = reconstruct_editor_state(bv_state)

    new_editor_state =
      Enum.reduce_while(Minga.Input.surface_handlers(), editor_state, fn handler, acc ->
        case handler.handle_key(acc, codepoint, modifiers) do
          {:handled, new_state} -> {:halt, new_state}
          {:passthrough, new_state} -> {:cont, new_state}
        end
      end)

    new_bv_state = Bridge.from_editor_state(new_editor_state)
    {new_bv_state, []}
  end

  @doc """
  Processes a mouse event for the buffer view.

  Walks the surface-level handlers that implement `handle_mouse/7`.
  Overlays have already been checked by the Editor.
  """
  @impl Minga.Surface
  @spec handle_mouse(
          BufferViewState.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: {BufferViewState.t(), [Minga.Surface.effect()]}
  def handle_mouse(
        %BufferViewState{context: nil} = bv_state,
        _row,
        _col,
        _button,
        _mods,
        _et,
        _cc
      ) do
    {bv_state, []}
  end

  def handle_mouse(%BufferViewState{} = bv_state, row, col, button, mods, event_type, click_count) do
    editor_state = reconstruct_editor_state(bv_state)

    new_editor_state =
      walk_mouse_handlers(editor_state, row, col, button, mods, event_type, click_count)

    new_bv_state = Bridge.from_editor_state(new_editor_state)
    {new_bv_state, []}
  end

  @doc """
  Renders the buffer view into the given rect.

  Reconstructs an EditorState with layout computed, then calls
  `RenderPipeline.run_windows_pipeline/2` for the actual scroll,
  content, chrome, compose, and emit stages.

  During Phase 1 the pipeline emits directly to the port, so the
  returned draw list is empty. The surface state is updated with
  refreshed render caches (per-window dirty-line tracking).
  """
  @impl Minga.Surface
  @spec render(
          BufferViewState.t(),
          {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}
        ) ::
          {BufferViewState.t(), [Minga.Editor.DisplayList.draw()]}
  def render(%BufferViewState{context: nil} = bv_state, _rect) do
    {bv_state, []}
  end

  def render(%BufferViewState{} = bv_state, _rect) do
    editor_state = reconstruct_editor_state(bv_state)

    # Pre-pipeline: sync cursor and compute layout (normally done by
    # RenderPipeline.run before delegating to the surface).
    editor_state = EditorState.sync_active_window_cursor(editor_state)
    editor_state = RenderPipeline.compute_layout(editor_state)
    layout = Layout.get(editor_state)

    new_editor_state = RenderPipeline.run_windows_pipeline(editor_state, layout)
    new_bv_state = Bridge.from_editor_state(new_editor_state)
    {new_bv_state, []}
  end

  @doc """
  Handles domain-specific events for the buffer view.

  Events include file watcher notifications, LSP responses, highlight
  spans, and diagnostic updates. During Phase 1, these are still
  handled by `Editor.handle_info` clauses and the bridge syncs the
  state changes back to the surface.
  """
  @impl Minga.Surface
  @spec handle_event(BufferViewState.t(), term()) ::
          {BufferViewState.t(), [Minga.Surface.effect()]}
  def handle_event(%BufferViewState{} = bv_state, _event) do
    # Phase 1: events are handled by Editor.handle_info and bridged.
    {bv_state, []}
  end

  @doc """
  Returns the cursor position and shape for the buffer view.

  Reads from the active window's cursor and the current vim mode to
  determine the cursor shape.
  """
  @impl Minga.Surface
  @spec cursor(BufferViewState.t()) ::
          {non_neg_integer(), non_neg_integer(), atom()}
  def cursor(%BufferViewState{editing: %{mode: mode}} = bv_state) do
    case bv_state.windows do
      %{active: active_id, map: map} when is_map_key(map, active_id) ->
        window = Map.fetch!(map, active_id)
        shape = cursor_shape(mode)
        {window.cursor_row, window.cursor_col, shape}

      _ ->
        {0, 0, cursor_shape(mode)}
    end
  end

  @doc """
  Called when this surface becomes the active tab.

  Restores the buffer view's state. During Phase 1, the Tab's context
  map is converted into a BufferView.State via the bridge in the
  Editor's tab-switching logic.
  """
  @impl Minga.Surface
  @spec activate(BufferViewState.t()) :: BufferViewState.t()
  def activate(%BufferViewState{} = bv_state) do
    bv_state
  end

  @doc """
  Called when this surface is backgrounded (another tab activated).

  The BufferView state is stored on the tab as-is. No manual field
  snapshotting needed because the surface owns its state directly.
  """
  @impl Minga.Surface
  @spec deactivate(BufferViewState.t()) :: BufferViewState.t()
  def deactivate(%BufferViewState{} = bv_state) do
    bv_state
  end

  # ── Bridge helpers ─────────────────────────────────────────────────────────

  @doc """
  Creates a BufferView.State from the current EditorState.

  Convenience wrapper around `Bridge.from_editor_state/1`.
  """
  @impl Minga.Surface
  @spec from_editor_state(Minga.Editor.State.t()) :: BufferViewState.t()
  defdelegate from_editor_state(editor_state), to: Bridge

  @doc """
  Writes BufferView.State changes back to the EditorState.

  Convenience wrapper around `Bridge.to_editor_state/2`.
  """
  @impl Minga.Surface
  @spec to_editor_state(Minga.Editor.State.t(), BufferViewState.t()) :: Minga.Editor.State.t()
  defdelegate to_editor_state(editor_state, bv_state), to: Bridge

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

  @spec cursor_shape(Minga.Mode.mode()) :: atom()
  defp cursor_shape(:insert), do: :beam
  defp cursor_shape(:search), do: :beam
  defp cursor_shape(:replace), do: :underline
  defp cursor_shape(_mode), do: :block

  # Builds an EditorState from the BufferView state and its shared context.
  # This is Phase 1 scaffolding: the focus stack handlers and render pipeline
  # operate on EditorState, so we reconstruct one for delegation. The context
  # carries the shared fields (theme, port_manager, etc.) that the surface
  # doesn't own.
  @spec reconstruct_editor_state(BufferViewState.t()) :: EditorState.t()
  defp reconstruct_editor_state(%BufferViewState{context: %Context{} = ctx, editing: vim} = bv) do
    # Build agent defaults for fields carried in context.
    # These are Phase 1 scaffolding: the agent fields live in context
    # so Input.Scoped's agent-panel branches work correctly.
    agent = ctx.agent || %Minga.Editor.State.Agent{}
    agentic = ctx.agentic || %Minga.Agent.View.State{}

    %EditorState{
      # Buffer-view owned fields
      buffers: bv.buffers,
      windows: bv.windows,
      file_tree: bv.file_tree,
      viewport: bv.viewport,
      mouse: bv.mouse,
      highlight: bv.highlight,
      lsp: bv.lsp,
      completion: bv.completion,
      completion_trigger: bv.completion_trigger,
      git_buffers: bv.git_buffers,
      injection_ranges: bv.injection_ranges,
      search: bv.search,
      pending_conflict: bv.pending_conflict,
      # Vim editing model fields
      mode: vim.mode,
      mode_state: vim.mode_state,
      reg: vim.reg,
      marks: vim.marks,
      last_jump_pos: vim.last_jump_pos,
      last_find_char: vim.last_find_char,
      change_recorder: vim.change_recorder,
      macro_recorder: vim.macro_recorder,
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
      # Agent fields (Phase 1 scaffolding, removed in Phase 2)
      agent: agent,
      agentic: agentic
    }
  end
end
