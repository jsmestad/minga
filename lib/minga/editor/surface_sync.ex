defmodule Minga.Editor.SurfaceSync do
  @moduledoc """
  DEPRECATED: Surface lifecycle stubs.

  This module is kept for backward compatibility during the refactor.
  The tab context system now stores per-tab fields directly instead of
  going through BufferViewState. All functions here are now no-ops.

  Will be deleted in a follow-up commit.
  """

  alias Minga.Editor.State, as: EditorState

  @doc "DEPRECATED: No-op. Surface initialization is no longer needed."
  @spec init_surface(EditorState.t()) :: EditorState.t()
  def init_surface(%EditorState{} = state), do: state

  @doc "DEPRECATED: No-op. Surface sync is no longer needed."
  @spec sync_from_editor(EditorState.t()) :: EditorState.t()
  def sync_from_editor(%EditorState{} = state), do: state

  @doc "DEPRECATED: No-op. Surface sync is no longer needed."
  @spec sync_to_editor(EditorState.t()) :: EditorState.t()
  def sync_to_editor(%EditorState{} = state), do: state

  @doc "DEPRECATED: No-op. Event dispatch through surfaces is no longer used."
  @spec dispatch_event(EditorState.t(), term()) :: {EditorState.t(), [Minga.Surface.effect()]}
  def dispatch_event(%EditorState{} = state, _event), do: {state, []}
end
