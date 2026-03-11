defmodule Minga.Editor.SurfaceSync do
  @moduledoc """
  Surface lifecycle: initialization, bidirectional sync, and event dispatch.

  The Surface abstraction (BufferView, AgentView) maintains its own state
  alongside EditorState. This module manages the bridge between them:
  creating surface state from EditorState, syncing changes in both
  directions, and dispatching events through the active surface.

  Extracted from `Minga.Editor` to reduce GenServer module size.
  """

  alias Minga.Editor.State, as: EditorState

  alias Minga.Surface.AgentView
  alias Minga.Surface.AgentView.Bridge, as: AVBridge
  alias Minga.Surface.AgentView.State, as: AVState
  alias Minga.Surface.BufferView
  alias Minga.Surface.BufferView.Bridge, as: BVBridge
  alias Minga.Surface.BufferView.State, as: BVState

  @doc """
  Initializes the surface for the current keymap scope.

  Agent scope creates an AgentView surface; everything else creates BufferView.
  """
  @spec init_surface(EditorState.t()) :: EditorState.t()
  def init_surface(%EditorState{keymap_scope: :agent} = state) do
    av_state = AVBridge.from_editor_state(state)
    %{state | surface_module: AgentView, surface_state: av_state}
  end

  def init_surface(%EditorState{} = state) do
    bv_state = BVBridge.from_editor_state(state)
    %{state | surface_module: BufferView, surface_state: bv_state}
  end

  @doc """
  Updates the surface state from the current EditorState fields.

  Call this after any operation that modifies EditorState fields that
  are also owned by the surface (buffers, windows, mode, etc.) to keep
  the surface state in sync.
  """
  @spec sync_from_editor(EditorState.t()) :: EditorState.t()
  def sync_from_editor(%EditorState{surface_module: BufferView} = state) do
    %{state | surface_state: BVBridge.from_editor_state(state)}
  end

  def sync_from_editor(%EditorState{surface_module: AgentView} = state) do
    %{state | surface_state: AVBridge.from_editor_state(state)}
  end

  def sync_from_editor(state), do: state

  @doc """
  Updates EditorState fields from the current surface state.

  Call this after a surface callback returns updated state to write
  the changes back to EditorState.
  """
  @spec sync_to_editor(EditorState.t()) :: EditorState.t()
  def sync_to_editor(
        %EditorState{surface_module: BufferView, surface_state: %BVState{} = bv} = state
      ) do
    BVBridge.to_editor_state(state, bv)
  end

  def sync_to_editor(
        %EditorState{surface_module: AgentView, surface_state: %AVState{} = av} = state
      ) do
    AVBridge.to_editor_state(state, av)
  end

  def sync_to_editor(state), do: state

  @doc """
  Dispatches an event through the active surface's handle_event callback.

  Syncs the surface state from EditorState, calls handle_event, writes
  back the updated surface state, and returns `{state, effects}` for
  the caller to apply.
  """
  @spec dispatch_event(EditorState.t(), term()) :: {EditorState.t(), [Minga.Surface.effect()]}
  def dispatch_event(%EditorState{surface_module: mod} = state, event)
      when mod != nil do
    state = sync_from_editor(state)
    {new_surface_state, effects} = mod.handle_event(state.surface_state, event)
    state = %{state | surface_state: new_surface_state}
    state = sync_to_editor(state)
    {state, effects}
  end

  def dispatch_event(state, _event), do: {state, []}
end
