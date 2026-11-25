defmodule MingaEditor.Input.WhichKey do
  @moduledoc """
  Gives an active which-key sequence first ownership of Escape, and walks the CUA space leader sequence.

  Escape closes which-key and cancels the pending leader sequence in the editing model, so the next `SPC` opens which-key again instead of continuing the old sequence (#4078).

  Vim walks its own leader sequence in the Normal mode state, so in Vim this handler passes every other key through. The CUA space leader keeps none: the macOS chord and retract (`CUA.SpaceLeader`) and the terminal retract window (`CUA.TUISpaceLeader`) start the sequence with `{:leader_start, node, prefix}`, so the which-key state is its only record. This handler resolves the next key inside that node before any surface sees it: a command runs, a prefix advances, Backspace goes back up one group (and closes which-key at the top, without reaching the surface), and any other key closes which-key and passes through to the focused surface.
  """

  @behaviour MingaEditor.Input.Handler

  alias Minga.Keymap.Bindings
  alias MingaEditor.Commands
  alias MingaEditor.Shell.Traditional.WhichKeyWorkflow

  @type state :: MingaEditor.Input.Handler.handler_state()

  @key_escape 27
  @key_backspace 127

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
        %{
          shell_runtime: %{state: %{whichkey: %MingaEditor.State.WhichKey{node: node} = whichkey}}
        } =
          state,
        codepoint,
        modifiers
      )
      when node != nil do
    if cua_leader?(state),
      do: continue_leader(state, whichkey, {codepoint, modifiers}),
      else: {:passthrough, state}
  end

  def handle_key(state, _codepoint, _modifiers), do: {:passthrough, state}

  # Only the CUA space leader leaves its sequence to which-key. A Vim which-key node without a mode
  # leader is stale (a click resets the mode), so the key belongs to the mode, not to the group.
  @spec cua_leader?(state()) :: boolean()
  defp cua_leader?(state) do
    Minga.Editing.active_model(state) == Minga.Editing.Model.CUA and
      not Minga.Editing.in_leader?(state)
  end

  @spec continue_leader(state(), MingaEditor.State.WhichKey.t(), Bindings.key()) ::
          MingaEditor.Input.Handler.result()
  defp continue_leader(state, whichkey, {@key_backspace, 0}) do
    case MingaEditor.State.WhichKey.parent(whichkey) do
      {:ok, parent, prefix_keys} ->
        {:handled, Commands.execute(state, {:leader_progress, parent, prefix_keys})}

      :top ->
        {:handled, Commands.execute(state, :leader_cancel)}
    end
  end

  defp continue_leader(state, %MingaEditor.State.WhichKey{node: node} = whichkey, key) do
    case Bindings.lookup(node, key) do
      {:command, command} ->
        {:handled, state |> Commands.execute(:leader_cancel) |> execute_command(command)}

      {:prefix, sub_node} ->
        prefix_keys = List.insert_at(whichkey.prefix_keys, -1, Bindings.format_key(key))
        {:handled, Commands.execute(state, {:leader_progress, sub_node, prefix_keys})}

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
