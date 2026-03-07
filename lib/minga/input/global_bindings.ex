defmodule Minga.Input.GlobalBindings do
  @moduledoc """
  Input handler for global key bindings that work in any mode.

  Currently handles Ctrl+S (save) and Ctrl+Q (quit). These bindings
  take priority over the mode FSM but yield to modal overlays (conflict
  prompt, picker, completion).
  """

  @behaviour Minga.Input.Handler

  import Bitwise

  require Logger

  alias Minga.Buffer.Server, as: BufferServer

  alias Minga.Port.Protocol
  @ctrl Protocol.mod_ctrl()

  @impl true
  @spec handle_key(Minga.Editor.State.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()

  # Ctrl+S: save current buffer
  def handle_key(state, ?s, mods) when band(mods, @ctrl) != 0 do
    if state.buffers.active do
      case BufferServer.save(state.buffers.active) do
        :ok -> :ok
        {:error, reason} -> Logger.error("Save failed: #{inspect(reason)}")
      end
    end

    {:handled, state}
  end

  # Ctrl+Q: quit
  def handle_key(state, ?q, mods) when band(mods, @ctrl) != 0 do
    System.stop(0)
    {:handled, state}
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end
end
