defmodule MingaEditor.Input.WhichKey do
  @moduledoc """
  Gives an active which-key sequence first ownership of Escape, and walks a leader sequence that no editing model owns.

  Escape closes which-key and cancels the pending leader sequence in the editing model, so the next `SPC` opens which-key again instead of continuing the old sequence (#4078).

  Vim walks its own leader sequence in the Normal mode state. The CUA space leader keeps none: the macOS chord and retract (`CUA.SpaceLeader`) and the terminal retract window (`CUA.TUISpaceLeader`) start the sequence with `{:leader_start, node}`, so the which-key node is its only record. This handler resolves the next key inside that node before any surface sees it: a command runs, a prefix advances, and any other key closes which-key and passes through to the focused surface.
  """

  @behaviour MingaEditor.Input.Handler

  alias Minga.Keymap.Bindings
  alias MingaEditor.Commands
  alias MingaEditor.Shell.Traditional.WhichKeyWorkflow

  @type state :: MingaEditor.Input.Handler.handler_state()

  @key_escape 27

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(
        %{shell_runtime: %{state: %{whichkey: %MingaEditor.State.WhichKey{node: node}}}} = state,
        @key_escape,
        _modifiers
      )
      when node != nil do
    {:handled,
     state
     |> WhichKeyWorkflow.dismiss()
     |> MingaEditor.Editing.update_mode_state(&Minga.Mode.cancel_leader/1)}
  end

  def handle_key(
        %{shell_runtime: %{state: %{whichkey: %MingaEditor.State.WhichKey{node: node}}}} = state,
        codepoint,
        modifiers
      )
      when node != nil do
    if Minga.Editing.in_leader?(state),
      do: {:passthrough, state},
      else: continue_leader(state, node, {codepoint, modifiers})
  end

  def handle_key(state, _codepoint, _modifiers), do: {:passthrough, state}

  @spec continue_leader(state(), Bindings.node_t(), Bindings.key()) ::
          MingaEditor.Input.Handler.result()
  defp continue_leader(state, node, key) do
    case Bindings.lookup(node, key) do
      {:command, command} ->
        {:handled, state |> Commands.execute(:leader_cancel) |> execute_command(command)}

      {:prefix, sub_node} ->
        {:handled, Commands.execute(state, {:leader_progress, sub_node})}

      :not_found ->
        {:passthrough, Commands.execute(state, :leader_cancel)}
    end
  end

  @spec execute_command(state(), atom() | tuple()) :: state()
  defp execute_command(state, command) do
    case Commands.execute(state, command) do
      {state, _action} -> state
      state -> state
    end
  end
end
