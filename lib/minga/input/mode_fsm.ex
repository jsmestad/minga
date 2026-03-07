defmodule Minga.Input.ModeFSM do
  @moduledoc """
  Input handler for the vim mode finite state machine.

  This is the fallback handler at the bottom of the focus stack. It
  processes keys through the mode system (normal, insert, visual,
  operator-pending, command, search, etc.) and dispatches resulting
  commands.
  """

  @behaviour Minga.Input.Handler

  @impl true
  @spec handle_key(Minga.Editor.State.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()
  def handle_key(state, codepoint, modifiers) do
    new_state = Minga.Editor.do_handle_key(state, codepoint, modifiers)
    {:handled, new_state}
  end
end
