defmodule Minga.Input.AgentPanel do
  @moduledoc """
  Input handler for the agent chat panel.

  When the agent panel is visible and input is focused, intercepts all
  keystrokes for the chat input. Escape unfocuses, Ctrl+C submits,
  printable characters are appended to the input text. Unrecognized
  keys are swallowed to prevent accidental mode transitions.

  This handler will be removed when the agent panel is converted to a
  real buffer (issue #130 step 2).
  """

  @behaviour Minga.Input.Handler

  import Bitwise

  require Logger

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.State.Agent, as: AgentState

  alias Minga.Port.Protocol
  @ctrl Protocol.mod_ctrl()
  @alt Protocol.mod_alt()

  @impl true
  @spec handle_key(Minga.Editor.State.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()

  def handle_key(%{agent: %{panel: %{visible: true, input_focused: true}}} = state, cp, mods) do
    {:handled, do_handle(state, cp, mods)}
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end

  # Ctrl+Q: quit (unfocus first, then forward the quit key)
  @spec do_handle(Minga.Editor.State.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Editor.State.t()
  defp do_handle(state, ?q, mods) when band(mods, @ctrl) != 0 do
    send(self(), {:minga_input, {:key_press, ?q, mods}})
    update_agent(state, &AgentState.focus_input(&1, false))
  end

  # Ctrl+S: save current buffer
  defp do_handle(state, ?s, mods) when band(mods, @ctrl) != 0 do
    if state.buffers.active do
      case BufferServer.save(state.buffers.active) do
        :ok -> :ok
        {:error, reason} -> Logger.error("Save failed: #{inspect(reason)}")
      end
    end

    _ = mods
    state
  end

  # Ctrl+C: submit prompt
  defp do_handle(state, ?c, mods) when band(mods, @ctrl) != 0 do
    AgentCommands.submit_prompt(state)
  end

  # Ctrl+D: scroll chat down
  defp do_handle(state, ?d, mods) when band(mods, @ctrl) != 0 do
    AgentCommands.scroll_chat_down(state)
  end

  # Ctrl+U: scroll chat up
  defp do_handle(state, ?u, mods) when band(mods, @ctrl) != 0 do
    AgentCommands.scroll_chat_up(state)
  end

  # Escape: unfocus the input
  defp do_handle(state, 27, _mods) do
    update_agent(state, &AgentState.focus_input(&1, false))
  end

  # Backspace
  defp do_handle(state, 127, _mods) do
    AgentCommands.input_backspace(state)
  end

  # Enter: submit prompt
  defp do_handle(state, 13, _mods) do
    AgentCommands.submit_prompt(state)
  end

  # Printable characters (no Ctrl/Alt)
  defp do_handle(state, cp, mods)
       when cp >= 32 and band(mods, @ctrl) == 0 and band(mods, @alt) == 0 do
    char = <<cp::utf8>>
    AgentCommands.input_char(state, char)
  end

  # Everything else: silently swallow
  defp do_handle(state, _cp, _mods), do: state

  @spec update_agent(Minga.Editor.State.t(), (AgentState.t() -> AgentState.t())) ::
          Minga.Editor.State.t()
  defp update_agent(state, fun) do
    %{state | agent: fun.(state.agent)}
  end
end
