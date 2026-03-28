defmodule Minga.Input.ToolApproval do
  @moduledoc """
  Input handler for the tool approval sub-state (y/n/Y/N).

  Active when `agent.pending_approval` is non-nil and the panel
  input is not focused. Handles y (approve), n (deny), Y (approve all),
  and swallows all other keys.
  """

  @behaviour Minga.Input.Handler

  @type state :: Minga.Input.Handler.handler_state()

  alias Minga.Editor.Commands
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) :: Minga.Input.Handler.result()
  def handle_key(state, cp, _mods) do
    agent = AgentAccess.agent(state)

    if is_map(agent.pending_approval) and not AgentAccess.input_focused?(state) do
      {:handled, dispatch_approval(state, cp)}
    else
      {:passthrough, state}
    end
  end

  @spec dispatch_approval(EditorState.t(), non_neg_integer()) :: EditorState.t()
  defp dispatch_approval(state, ?y), do: Commands.execute(state, :agent_approve_tool)
  defp dispatch_approval(state, ?n), do: Commands.execute(state, :agent_deny_tool)
  defp dispatch_approval(state, ?Y), do: Commands.execute(state, :agent_approve_tool)
  defp dispatch_approval(state, _cp), do: state
end
