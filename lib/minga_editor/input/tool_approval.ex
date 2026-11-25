defmodule MingaEditor.Input.ToolApproval do
  @moduledoc """
  Input handler for the tool approval sub-state (y/Enter/a/t/n).

  Active when `agent.pending_approval` is non-nil, the panel
  input is not focused, and neither a command line, search, or eval prompt nor a pending key sequence owns the key. Handles y or Enter (approve), a (trust this tool for the session),
  t (trust this tool for the current turn) and n (deny). Esc defers: it continues through normal editor routing and leaves the request pending, so it stays answerable. Unrelated keys continue the same way.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  alias MingaEditor.Commands
  alias MingaEditor.State, as: EditorState

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(state, cp, 0) do
    agent = MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)

    # An open command line or pending sequence owns every key, so typing `:qa`
    # or `SPC h k a` never trusts a tool.
    if is_map(agent.pending_approval) and not state.workspace.agent_ui.panel.input_focused and
         not Minga.Editing.owns_next_key?(state) do
      dispatch_approval(state, cp)
    else
      {:passthrough, state}
    end
  end

  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  @spec dispatch_approval(EditorState.t(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  defp dispatch_approval(state, ?y), do: {:handled, Commands.execute(state, :agent_approve_tool)}
  defp dispatch_approval(state, 13), do: {:handled, Commands.execute(state, :agent_approve_tool)}

  defp dispatch_approval(state, ?a),
    do: {:handled, Commands.execute(state, :agent_trust_tool_session)}

  defp dispatch_approval(state, ?t),
    do: {:handled, Commands.execute(state, :agent_trust_tool_turn)}

  defp dispatch_approval(state, ?n), do: {:handled, Commands.execute(state, :agent_deny_tool)}
  defp dispatch_approval(state, _cp), do: {:passthrough, state}
end
