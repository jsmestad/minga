defmodule Minga.Input.ToolApproval do
  @moduledoc """
  Input handler for the tool approval sub-state (y/n/Y/N).

  Active when `agent.pending_approval` is non-nil and the panel
  input is not focused. Handles y (approve), n (deny), Y (approve all),
  and swallows all other keys.
  """

  @behaviour Minga.Input.Handler

  alias Minga.Editor.Commands
  alias Minga.Editor.State, as: EditorState

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}
  def handle_key(
        %{agent: %{pending_approval: approval, panel: %{input_focused: false}}} = state,
        cp,
        _mods
      )
      when is_map(approval) do
    {:handled, dispatch_approval(state, cp)}
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end

  @spec dispatch_approval(EditorState.t(), non_neg_integer()) :: EditorState.t()
  defp dispatch_approval(state, ?y), do: Commands.execute(state, :agent_approve_tool)
  defp dispatch_approval(state, ?n), do: Commands.execute(state, :agent_deny_tool)
  defp dispatch_approval(state, ?Y), do: Commands.execute(state, :agent_approve_tool)
  defp dispatch_approval(state, _cp), do: state
end
