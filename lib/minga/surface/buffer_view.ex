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

  alias Minga.Surface.BufferView.Bridge
  alias Minga.Surface.BufferView.State, as: BVState

  # ── Surface callbacks ──────────────────────────────────────────────────────

  @impl Minga.Surface
  @spec scope() :: :editor
  def scope, do: :editor

  @doc """
  Processes a key press for the buffer view.

  During Phase 1, the Editor still dispatches keys through the focus
  stack (overlays, Input.Scoped, ModeFSM). This callback is wired in
  but delegates back through the existing pipeline via the bridge.

  The Editor calls this when the active surface is BufferView and no
  overlay has consumed the key. The implementation converts
  BufferView.State to EditorState, runs the key through the existing
  handlers, and converts back.
  """
  @impl Minga.Surface
  @spec handle_key(BVState.t(), non_neg_integer(), non_neg_integer()) ::
          {BVState.t(), [Minga.Surface.effect()]}
  def handle_key(%BVState{} = bv_state, _codepoint, _modifiers) do
    # Phase 1: input dispatch still goes through the Editor's focus stack.
    # This callback exists to satisfy the behaviour contract. The Editor
    # calls the focus stack directly and updates the surface state via
    # the bridge after dispatch.
    {bv_state, []}
  end

  @doc """
  Processes a mouse event for the buffer view.

  Same Phase 1 delegation pattern as `handle_key/3`.
  """
  @impl Minga.Surface
  @spec handle_mouse(
          BVState.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: {BVState.t(), [Minga.Surface.effect()]}
  def handle_mouse(%BVState{} = bv_state, _row, _col, _button, _mods, _event_type, _cc) do
    # Phase 1: mouse dispatch still goes through Input.Router.dispatch_mouse.
    {bv_state, []}
  end

  @doc """
  Renders the buffer view into the given rect.

  During Phase 1, the RenderPipeline's `run_windows` path handles
  rendering via the bridge. This callback returns an empty draw list.
  The Editor calls `RenderPipeline.run/1` with the full EditorState
  (reconstructed via the bridge) and the pipeline produces the frame.
  """
  @impl Minga.Surface
  @spec render(BVState.t(), {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}) ::
          {BVState.t(), [Minga.Editor.DisplayList.draw()]}
  def render(%BVState{} = bv_state, _rect) do
    # Phase 1: rendering goes through RenderPipeline.run/1 with the
    # full EditorState. The surface's render callback will take over
    # in a later phase.
    {bv_state, []}
  end

  @doc """
  Handles domain-specific events for the buffer view.

  Events include file watcher notifications, LSP responses, highlight
  spans, and diagnostic updates. During Phase 1, these are still
  handled by `Editor.handle_info` clauses and the bridge syncs the
  state changes back to the surface.
  """
  @impl Minga.Surface
  @spec handle_event(BVState.t(), term()) :: {BVState.t(), [Minga.Surface.effect()]}
  def handle_event(%BVState{} = bv_state, _event) do
    # Phase 1: events are handled by Editor.handle_info and bridged.
    {bv_state, []}
  end

  @doc """
  Returns the cursor position and shape for the buffer view.

  Reads from the active window's cursor and the current vim mode to
  determine the cursor shape.
  """
  @impl Minga.Surface
  @spec cursor(BVState.t()) ::
          {non_neg_integer(), non_neg_integer(), atom()}
  def cursor(%BVState{editing: %{mode: mode}} = bv_state) do
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
  @spec activate(BVState.t()) :: BVState.t()
  def activate(%BVState{} = bv_state) do
    bv_state
  end

  @doc """
  Called when this surface is backgrounded (another tab activated).

  The BufferView state is stored on the tab as-is. No manual field
  snapshotting needed because the surface owns its state directly.
  """
  @impl Minga.Surface
  @spec deactivate(BVState.t()) :: BVState.t()
  def deactivate(%BVState{} = bv_state) do
    bv_state
  end

  # ── Bridge helpers ─────────────────────────────────────────────────────────

  @doc """
  Creates a BufferView.State from the current EditorState.

  Convenience wrapper around `Bridge.from_editor_state/1`.
  """
  @spec from_editor_state(Minga.Editor.State.t()) :: BVState.t()
  defdelegate from_editor_state(editor_state), to: Bridge

  @doc """
  Writes BufferView.State changes back to the EditorState.

  Convenience wrapper around `Bridge.to_editor_state/2`.
  """
  @spec to_editor_state(Minga.Editor.State.t(), BVState.t()) :: Minga.Editor.State.t()
  defdelegate to_editor_state(editor_state, bv_state), to: Bridge

  # ── Private ────────────────────────────────────────────────────────────────

  @spec cursor_shape(Minga.Mode.mode()) :: atom()
  defp cursor_shape(:insert), do: :bar
  defp cursor_shape(:replace), do: :underline
  defp cursor_shape(_mode), do: :block
end
