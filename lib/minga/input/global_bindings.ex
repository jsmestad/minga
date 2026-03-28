defmodule Minga.Input.GlobalBindings do
  @moduledoc """
  Input handler for global key bindings that work in any mode.

  Currently handles Ctrl+S (save) and Ctrl+Q (quit). These bindings
  take priority over the mode FSM but yield to modal overlays (conflict
  prompt, picker, completion).
  """

  @behaviour Minga.Input.Handler

  @type state :: Minga.Input.Handler.handler_state()

  import Bitwise

  alias Minga.Buffer

  @ctrl Minga.Input.mod_ctrl()

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) :: Minga.Input.Handler.result()

  # Ctrl+S: save current buffer
  def handle_key(state, ?s, mods) when band(mods, @ctrl) != 0 do
    if state.workspace.buffers.active do
      case Buffer.save(state.workspace.buffers.active) do
        :ok -> :ok
        {:error, reason} -> Minga.Log.error(:editor, "Save failed: #{inspect(reason)}")
      end
    end

    {:handled, state}
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

    new_state = Minga.Editor.dispatch_command(state, command)
    {:handled, new_state}
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end
end
