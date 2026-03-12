defmodule Minga.Editor.SurfaceSync do
  @moduledoc """
  Surface lifecycle: initialization, bidirectional sync, and event dispatch.

  The Surface abstraction (BufferView, AgentView) maintains its own state
  alongside EditorState. This module manages the bridge between them:
  creating surface state from EditorState, syncing changes in both
  directions, and dispatching events through the active surface.

  All sync operations dispatch through the Surface behaviour's
  `from_editor_state/1` and `to_editor_state/2` callbacks, making this
  module generic: adding a new surface implementation requires no changes here.
  """

  alias Minga.Editor.State, as: EditorState
  alias Minga.Surface.AgentView
  alias Minga.Surface.BufferView

  @doc """
  Initializes the surface for the current keymap scope.

  Agent scope creates an AgentView surface; everything else creates BufferView.
  """
  @spec init_surface(EditorState.t()) :: EditorState.t()
  def init_surface(%EditorState{keymap_scope: :agent} = state) do
    surface_state = AgentView.from_editor_state(state)
    %{state | surface_module: AgentView, surface_state: surface_state}
  end

  def init_surface(%EditorState{} = state) do
    surface_state = BufferView.from_editor_state(state)
    %{state | surface_module: BufferView, surface_state: surface_state}
  end

  @doc """
  Updates the surface state from the current EditorState fields.

  Call this after any operation that modifies EditorState fields that
  are also owned by the surface (buffers, windows, mode, etc.) to keep
  the surface state in sync.
  """
  @spec sync_from_editor(EditorState.t()) :: EditorState.t()
  def sync_from_editor(%EditorState{surface_module: mod} = state) when mod != nil do
    %{state | surface_state: mod.from_editor_state(state)}
  end

  def sync_from_editor(state), do: state

  @doc """
  Updates EditorState fields from the current surface state.

  Call this after a surface callback returns updated state to write
  the changes back to EditorState.
  """
  @spec sync_to_editor(EditorState.t()) :: EditorState.t()
  def sync_to_editor(%EditorState{surface_module: mod, surface_state: ss} = state)
      when mod != nil and ss != nil do
    mod.to_editor_state(state, ss)
  end

  def sync_to_editor(state), do: state

  @doc """
  Dispatches an event through the active surface's handle_event callback.

  Calls handle_event directly on the current surface_state (no bridge
  round-trip). Surface events operate on their own state and return
  effects for the Editor to apply.
  """
  @spec dispatch_event(EditorState.t(), term()) :: {EditorState.t(), [Minga.Surface.effect()]}
  def dispatch_event(%EditorState{surface_module: mod, surface_state: ss} = state, event)
      when mod != nil and ss != nil do
    {new_surface_state, effects} = mod.handle_event(ss, event)
    {%{state | surface_state: new_surface_state}, effects}
  end

  def dispatch_event(state, _event), do: {state, []}
end
