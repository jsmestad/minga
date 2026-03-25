defmodule Minga.Input.GlobalBindings do
  @moduledoc """
  Input handler for global key bindings that work in any mode.

  Currently handles Ctrl+S (save) and Ctrl+Q (quit). These bindings
  take priority over the mode FSM but yield to modal overlays (conflict
  prompt, picker, completion).
  """

  @behaviour Minga.Input.Handler

  import Bitwise

  alias Minga.Buffer.Server, as: BufferServer

  @ctrl Minga.Input.mod_ctrl()

  @impl true
  @spec handle_key(Minga.Editor.State.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()

  # Ctrl+S: save current buffer
  def handle_key(state, ?s, mods) when band(mods, @ctrl) != 0 do
    if state.workspace.buffers.active do
      case BufferServer.save(state.workspace.buffers.active) do
        :ok -> :ok
        {:error, reason} -> Minga.Log.error(:editor, "Save failed: #{inspect(reason)}")
      end
    end

    {:handled, state}
  end

  # Ctrl+Q: close tab or quit (tab-aware, matches :q behavior)
  def handle_key(state, ?q, mods) when band(mods, @ctrl) != 0 do
    new_state = Minga.Editor.dispatch_command(state, :quit)
    {:handled, new_state}
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end
end
