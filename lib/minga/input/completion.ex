defmodule Minga.Input.Completion do
  @moduledoc """
  Input handler for the completion popup in insert mode.

  When a completion popup is visible and the editor is in insert mode,
  intercepts navigation keys (C-n, C-p, arrows), accept keys (Tab, Enter),
  and Escape. Other keys pass through to the mode FSM for normal insert
  handling.
  """

  @behaviour Minga.Input.Handler

  import Bitwise

  alias Minga.Completion

  alias Minga.Port.Protocol
  @ctrl Protocol.mod_ctrl()
  @escape 27
  @tab 9
  @enter 13
  @arrow_up 0x415B1B
  @arrow_down 0x425B1B

  @impl true
  @spec handle_key(Minga.Editor.State.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()
  def handle_key(%{mode: :insert, completion: %Completion{} = completion} = state, cp, mods) do
    case do_handle(state, completion, cp, mods) do
      {:handled, new_state} -> {:handled, new_state}
      :passthrough -> {:passthrough, state}
    end
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end

  @spec do_handle(Minga.Editor.State.t(), Completion.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, Minga.Editor.State.t()} | :passthrough

  # Escape: dismiss completion and stay in insert mode
  defp do_handle(state, _completion, @escape, _mods) do
    {:handled, Minga.Editor.do_dismiss_completion(state)}
  end

  # C-n or arrow down: move selection down
  defp do_handle(state, completion, cp, mods)
       when (cp == ?n and band(mods, @ctrl) != 0) or cp == @arrow_down do
    {:handled, %{state | completion: Completion.move_down(completion)}}
  end

  # C-p or arrow up: move selection up
  defp do_handle(state, completion, cp, mods)
       when (cp == ?p and band(mods, @ctrl) != 0) or cp == @arrow_up do
    {:handled, %{state | completion: Completion.move_up(completion)}}
  end

  # Tab or Enter: accept the selected completion
  defp do_handle(state, completion, cp, _mods) when cp in [@tab, @enter] do
    new_state = Minga.Editor.do_accept_completion(state, completion)
    {:handled, new_state}
  end

  # All other keys: pass through
  defp do_handle(_state, _completion, _cp, _mods), do: :passthrough
end
