defmodule MingaEditor.Input.ModeFSM do
  @moduledoc """
  Input handler for the vim mode finite state machine.

  This is the fallback handler at the bottom of the focus stack. It
  processes keys through the mode system (normal, insert, visual,
  operator-pending, command, search, etc.) and dispatches resulting
  commands.

  Also serves as the fallback mouse handler, delegating to
  `MingaEditor.Mouse.handle/7` for editor-level mouse interactions.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  alias MingaEditor.Mouse

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(state, codepoint, modifiers) do
    new_state = MingaEditor.do_handle_key(state, codepoint, modifiers)
    {:handled, new_state}
  end

  @impl true
  @spec handle_mouse(
          state(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: MingaEditor.Input.Handler.result()
  def handle_mouse(state, row, col, button, mods, event_type, click_count) do
    new_state = Mouse.handle(state, row, col, button, mods, event_type, click_count)
    {:handled, new_state}
  end
end
