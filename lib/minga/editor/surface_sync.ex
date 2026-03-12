defmodule Minga.Editor.SurfaceSync do
  @moduledoc """
  Surface lifecycle: initialization, bidirectional sync, and event dispatch.

  Manages the bridge between EditorState and the active Surface
  (currently only BufferView). Agent state lives directly on
  EditorState and is handled by `Minga.Agent.Events`.
  """

  alias Minga.Editor.State, as: EditorState
  alias Minga.Surface.BufferView

  @doc """
  Initializes the surface. Always creates a BufferView surface.
  """
  @spec init_surface(EditorState.t()) :: EditorState.t()
  def init_surface(%EditorState{} = state) do
    surface_state = BufferView.from_editor_state(state)
    %{state | surface_module: BufferView, surface_state: surface_state}
  end

  @doc """
  Updates the surface state from the current EditorState fields.
  """
  @spec sync_from_editor(EditorState.t()) :: EditorState.t()
  def sync_from_editor(%EditorState{surface_module: mod} = state) when mod != nil do
    %{state | surface_state: mod.from_editor_state(state)}
  end

  def sync_from_editor(state), do: state

  @doc """
  Updates EditorState fields from the current surface state.
  """
  @spec sync_to_editor(EditorState.t()) :: EditorState.t()
  def sync_to_editor(%EditorState{surface_module: mod, surface_state: ss} = state)
      when mod != nil and ss != nil do
    mod.to_editor_state(state, ss)
  end

  def sync_to_editor(state), do: state

  @doc """
  Dispatches an event through the active surface's handle_event callback.

  Used for BufferView events (file watcher notifications, etc.).
  Agent events go through `Minga.Agent.Events.handle/2` directly.
  """
  @spec dispatch_event(EditorState.t(), term()) :: {EditorState.t(), [Minga.Surface.effect()]}
  def dispatch_event(%EditorState{surface_module: mod, surface_state: ss} = state, event)
      when mod != nil and ss != nil do
    {new_surface_state, effects} = mod.handle_event(ss, event)
    {%{state | surface_state: new_surface_state}, effects}
  end

  def dispatch_event(state, _event), do: {state, []}
end
