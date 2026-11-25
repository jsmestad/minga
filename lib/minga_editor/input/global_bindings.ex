defmodule MingaEditor.Input.GlobalBindings do
  @moduledoc """
  Input handler for global key bindings that work in any mode.

  Currently handles Ctrl+S and Cmd+S (save) and Ctrl+Q (quit). These bindings
  take priority over the mode FSM but yield to modal overlays (conflict
  prompt, picker, completion).

  Cmd+S is the macOS platform key for save. It sits here beside Ctrl+S, and not in a scope as an alias under rule 5 of `docs/design/keys.md`, so that it saves in every mode as the macOS menu item does; this handler is outside the key grammar's inventory, as Ctrl+S is. The macOS app runs Save from its menu and never sends the key, so it arrives here only from a terminal that reports Cmd (the Kitty keyboard protocol). In the CUA profile the Editor scope binds Cmd+S itself and runs first, so one press saves once.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  import Bitwise

  @ctrl MingaEditor.Input.mod_ctrl()
  @cmd 0x08

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()

  # Ctrl+S or Cmd+S: save current buffer through the command system.
  def handle_key(state, ?s, mods) when band(mods, @ctrl) != 0 or mods == @cmd do
    new_state = MingaEditor.dispatch_command(state, :save)
    {:handled, new_state}
  end

  # Ctrl+Q: quit behavior depends on editing model.
  # CUA mode: quit the entire editor (users expect Ctrl+Q = exit app).
  # Vim mode: close current tab (:q behavior; use SPC q q for full quit).
  def handle_key(state, ?q, mods) when band(mods, @ctrl) != 0 do
    command =
      if Minga.Editing.active_model(state) == Minga.Editing.Model.CUA do
        :quit_all
      else
        :quit
      end

    new_state = MingaEditor.dispatch_command(state, command)
    {:handled, new_state}
  end

  @escape 27

  def handle_key(state, @escape, 0) do
    case MingaEditor.Commands.Formatting.cancel_pending_format(state) do
      {:canceled, state} ->
        {:passthrough,
         MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "Format canceled")}

      :none ->
        {:passthrough, state}
    end
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end
end
