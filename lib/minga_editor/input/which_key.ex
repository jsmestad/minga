defmodule MingaEditor.Input.WhichKey do
  @moduledoc """
  Gives an active which-key sequence first ownership of Escape.

  Escape closes which-key and cancels the pending leader sequence in the editing model, so the next `SPC` opens which-key again instead of continuing the old sequence (#4078).
  """

  @behaviour MingaEditor.Input.Handler

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

  def handle_key(state, _codepoint, _modifiers), do: {:passthrough, state}
end
