defmodule MingaBoard.Shell.AgentDeactivation do
  @moduledoc """
  Clears the shell-level agent rendering cache when leaving a Board card.

  Symmetric counterpart to the activation step that runs on zoom-in: when
  the user zooms out of a card, the cached `runtime`, `pending_approval`,
  and `error` fields on `state.shell_state.agent` belong to the card the
  user just left. The grid view must not show those.

  This is narrower than `MingaBoard.AgentActivation.deactivate/1`, which
  also resets workspace-level fields (keymap scope, prompt focus). On
  zoom-out the workspace is replaced by the grid snapshot via
  `restore_tab_context/2`, so workspace-level cleanup is unnecessary.
  Resetting only the shell-level cache keeps the responsibility on this
  module clear.
  """

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess

  @doc """
  Resets the agent rendering cache (`runtime`, `pending_approval`, `error`).

  Call from `ZoomOut.zoom_out/1` before restoring the grid workspace so the
  grid renders against an idle cache.
  """
  @spec deactivate_agent_for_card(EditorState.t()) :: EditorState.t()
  def deactivate_agent_for_card(%EditorState{} = state) do
    AgentAccess.update_agent(state, &AgentState.reset_cache/1)
  end
end
