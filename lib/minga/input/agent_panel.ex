defmodule Minga.Input.AgentPanel do
  @moduledoc """
  Input handler for the agent chat panel.

  Two modes of operation:

  1. **Input focused** (`input_focused: true`): all keystrokes go to the
     chat input field. Escape unfocuses, Enter/Ctrl+C submits, printable
     chars are appended to input text.

  2. **Panel focused, input not focused** (`visible: true, input_focused: false`):
     navigation keys (j, k, gg, G, Ctrl-d, Ctrl-u, /, etc.) are delegated
     to the mode FSM with the `*Agent*` buffer as the active buffer, giving
     full vim navigation of the chat content. `i` re-focuses the input.
     `q`/Escape closes the panel.
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

  # Input focused: intercept all keystrokes for the input field
  def handle_key(%{agent: %{panel: %{visible: true, input_focused: true}}} = state, cp, mods) do
    {:handled, handle_input(state, cp, mods)}
  end

  # Panel visible but input not focused: vim navigation mode
  def handle_key(
        %{agent: %{panel: %{visible: true}, buffer: buf}} = state,
        cp,
        mods
      )
      when is_pid(buf) do
    case handle_navigation(state, cp, mods) do
      {:panel_handled, new_state} -> {:handled, new_state}
      :delegate_to_fsm -> {:handled, delegate_to_mode_fsm(state, cp, mods)}
    end
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end

  # ── Input mode ─────────────────────────────────────────────────────────

  @spec handle_input(Minga.Editor.State.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Editor.State.t()

  # Ctrl+Q: quit (unfocus first, then forward the quit key)
  defp handle_input(state, ?q, mods) when band(mods, @ctrl) != 0 do
    send(self(), {:minga_input, {:key_press, ?q, mods}})
    update_agent(state, &AgentState.focus_input(&1, false))
  end

  # Ctrl+S: save current buffer
  defp handle_input(state, ?s, mods) when band(mods, @ctrl) != 0 do
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
  defp handle_input(state, ?c, mods) when band(mods, @ctrl) != 0 do
    AgentCommands.submit_prompt(state)
  end

  # Ctrl+D: scroll chat down
  defp handle_input(state, ?d, mods) when band(mods, @ctrl) != 0 do
    AgentCommands.scroll_chat_down(state)
  end

  # Ctrl+U: scroll chat up
  defp handle_input(state, ?u, mods) when band(mods, @ctrl) != 0 do
    AgentCommands.scroll_chat_up(state)
  end

  # Escape: unfocus the input (back to navigation mode)
  defp handle_input(state, 27, _mods) do
    update_agent(state, &AgentState.focus_input(&1, false))
  end

  # Backspace
  defp handle_input(state, 127, _mods) do
    AgentCommands.input_backspace(state)
  end

  # Enter: submit prompt
  defp handle_input(state, 13, _mods) do
    AgentCommands.submit_prompt(state)
  end

  # Printable characters (no Ctrl/Alt)
  defp handle_input(state, cp, mods)
       when cp >= 32 and band(mods, @ctrl) == 0 and band(mods, @alt) == 0 do
    char = <<cp::utf8>>
    AgentCommands.input_char(state, char)
  end

  # Everything else: silently swallow
  defp handle_input(state, _cp, _mods), do: state

  # ── Navigation mode (panel visible, input not focused) ─────────────────

  @spec handle_navigation(Minga.Editor.State.t(), non_neg_integer(), non_neg_integer()) ::
          {:panel_handled, Minga.Editor.State.t()} | :delegate_to_fsm

  # q or Escape: close the panel
  defp handle_navigation(state, cp, _mods) when cp in [?q, 27] do
    {:panel_handled, AgentCommands.toggle_panel(state)}
  end

  # i: focus the input field
  defp handle_navigation(state, ?i, _mods) do
    {:panel_handled, update_agent(state, &AgentState.focus_input(&1, true))}
  end

  # Everything else: delegate to mode FSM for vim navigation
  defp handle_navigation(_state, _cp, _mods), do: :delegate_to_fsm

  # ── Mode FSM delegation ───────────────────────────────────────────────

  @spec delegate_to_mode_fsm(Minga.Editor.State.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Editor.State.t()
  defp delegate_to_mode_fsm(%{agent: %{buffer: buf}} = state, cp, mods) when is_pid(buf) do
    # Swap active buffer to agent buffer
    real_active = state.buffers.active
    state = put_in(state.buffers.active, buf)

    # Run through the mode FSM
    state = Minga.Editor.do_handle_key(state, cp, mods)

    # Block mode transitions (buffer is read-only, navigation only)
    state =
      if state.mode != :normal do
        %{state | mode: :normal, mode_state: Minga.Mode.initial_state()}
      else
        state
      end

    # Restore the real active buffer
    put_in(state.buffers.active, real_active)
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  @spec update_agent(Minga.Editor.State.t(), (AgentState.t() -> AgentState.t())) ::
          Minga.Editor.State.t()
  defp update_agent(state, fun) do
    %{state | agent: fun.(state.agent)}
  end
end
