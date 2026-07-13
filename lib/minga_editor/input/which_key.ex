defmodule MingaEditor.Input.WhichKey do
  @moduledoc "Gives an active which-key sequence first ownership of Escape."

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
    {:handled, WhichKeyWorkflow.dismiss(state)}
  end

  def handle_key(state, _codepoint, _modifiers), do: {:passthrough, state}
end
