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

  alias Minga.Agent.FileMention
  alias Minga.Agent.PanelState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.State.Agent, as: AgentState

  alias Minga.Port.Protocol
  @ctrl Protocol.mod_ctrl()
  @alt Protocol.mod_alt()
  @shift Protocol.mod_shift()
  @arrow_up 0x415B1B
  @arrow_down 0x425B1B

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

  # ── Mention completion active ──────────────────────────────────────────

  # When the @-mention completion popup is open, intercept Tab, Enter, Esc,
  # Backspace, and printable chars to drive the popup instead of the input.

  # Tab with Shift: select previous completion candidate
  defp handle_input(
         %{agent: %{panel: %{mention_completion: %{} = _comp}}} = state,
         9,
         mods
       )
       when band(mods, @shift) != 0 do
    update_panel(state, fn p ->
      %{p | mention_completion: FileMention.select_prev(p.mention_completion)}
    end)
  end

  # Tab: select next completion candidate
  defp handle_input(%{agent: %{panel: %{mention_completion: %{} = _comp}}} = state, 9, _mods) do
    update_panel(state, fn p ->
      %{p | mention_completion: FileMention.select_next(p.mention_completion)}
    end)
  end

  # Enter: accept the selected candidate
  defp handle_input(
         %{agent: %{panel: %{mention_completion: %{} = _comp}}} = state,
         13,
         _mods
       ) do
    accept_mention_completion(state)
  end

  # Escape: cancel completion
  defp handle_input(%{agent: %{panel: %{mention_completion: %{} = _comp}}} = state, 27, _mods) do
    cancel_mention_completion(state)
  end

  # Backspace: shorten prefix or cancel if empty
  defp handle_input(
         %{agent: %{panel: %{mention_completion: %{} = _comp}}} = state,
         127,
         _mods
       ) do
    handle_mention_backspace(state)
  end

  # Printable chars: filter completion
  defp handle_input(
         %{agent: %{panel: %{mention_completion: %{} = _comp}}} = state,
         cp,
         mods
       )
       when cp >= 32 and band(mods, @ctrl) == 0 and band(mods, @alt) == 0 do
    char = <<cp::utf8>>
    handle_mention_char(state, char)
  end

  # ── Regular input (no completion popup) ─────────────────────────────────

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

  # Ctrl+C: submit prompt if input has text, abort if agent is active
  defp handle_input(state, ?c, mods) when band(mods, @ctrl) != 0 do
    input = PanelState.input_text(state.agent.panel)

    if input == "" do
      if state.agent.status in [:thinking, :tool_executing] do
        AgentCommands.abort_agent(state)
      else
        state
      end
    else
      AgentCommands.submit_prompt(state)
    end
  end

  # Ctrl+D: scroll chat down
  defp handle_input(state, ?d, mods) when band(mods, @ctrl) != 0 do
    AgentCommands.scroll_chat_down(state)
  end

  # Ctrl+U: scroll chat up
  defp handle_input(state, ?u, mods) when band(mods, @ctrl) != 0 do
    AgentCommands.scroll_chat_up(state)
  end

  # Ctrl+L: clear chat display
  defp handle_input(state, ?l, mods) when band(mods, @ctrl) != 0 do
    AgentCommands.clear_chat_display(state)
  end

  # Escape: unfocus the input (back to navigation mode)
  defp handle_input(state, 27, _mods) do
    update_agent(state, &AgentState.focus_input(&1, false))
  end

  # Backspace
  defp handle_input(state, 127, _mods) do
    AgentCommands.input_backspace(state)
  end

  # Shift+Enter or Alt+Enter: insert newline
  defp handle_input(state, 13, mods) when band(mods, @shift) != 0 do
    update_agent(state, &AgentState.insert_newline/1)
  end

  defp handle_input(state, 13, mods) when band(mods, @alt) != 0 do
    update_agent(state, &AgentState.insert_newline/1)
  end

  # Enter: submit prompt
  defp handle_input(state, 13, _mods) do
    AgentCommands.submit_prompt(state)
  end

  # Up arrow: move cursor up or recall history
  defp handle_input(state, @arrow_up, _mods) do
    case AgentState.move_cursor_up(state.agent) do
      :at_top -> update_agent(state, &AgentState.history_prev/1)
      agent -> %{state | agent: agent}
    end
  end

  # Down arrow: move cursor down or forward history
  defp handle_input(state, @arrow_down, _mods) do
    case AgentState.move_cursor_down(state.agent) do
      :at_bottom -> update_agent(state, &AgentState.history_next/1)
      agent -> %{state | agent: agent}
    end
  end

  # @ at start of line or after whitespace: trigger mention completion
  defp handle_input(state, ?@, mods) when band(mods, @ctrl) == 0 and band(mods, @alt) == 0 do
    if should_trigger_mention?(state) do
      state = AgentCommands.input_char(state, "@")
      start_mention_completion(state)
    else
      AgentCommands.input_char(state, "@")
    end
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

  @spec update_panel(
          Minga.Editor.State.t(),
          (PanelState.t() -> PanelState.t())
        ) :: Minga.Editor.State.t()
  defp update_panel(state, fun) do
    update_agent(state, fn agent ->
      %{agent | panel: fun.(agent.panel)}
    end)
  end

  # ── Mention completion helpers ──────────────────────────────────────────

  @spec should_trigger_mention?(Minga.Editor.State.t()) :: boolean()
  defp should_trigger_mention?(state) do
    panel = state.agent.panel
    {line, col} = panel.input_cursor
    current_line = Enum.at(panel.input_lines, line, "")
    # @ triggers if at start of line or the character before cursor is whitespace
    col == 0 or String.at(current_line, col - 1) in [" ", "\t", nil]
  end

  @spec start_mention_completion(Minga.Editor.State.t()) :: Minga.Editor.State.t()
  defp start_mention_completion(state) do
    files = list_project_files()
    {line, col} = state.agent.panel.input_cursor
    # anchor_col is where the @ was typed (one char before current cursor)
    completion = FileMention.new_completion(files, line, col - 1)
    update_panel(state, fn p -> %{p | mention_completion: completion} end)
  end

  @spec accept_mention_completion(Minga.Editor.State.t()) :: Minga.Editor.State.t()
  defp accept_mention_completion(state) do
    comp = state.agent.panel.mention_completion

    case FileMention.selected_path(comp) do
      nil ->
        update_panel(state, fn p -> %{p | mention_completion: nil} end)

      path ->
        # Replace the @prefix with @path in the input
        panel = state.agent.panel
        {line, _col} = panel.input_cursor
        current = Enum.at(panel.input_lines, line)
        anchor_col = comp.anchor_col

        # Everything before the @, the completed @path, everything after the typed prefix
        before = String.slice(current, 0, anchor_col)

        after_prefix =
          String.slice(
            current,
            anchor_col + 1 + String.length(comp.prefix),
            String.length(current)
          )

        new_line = before <> "@" <> path <> " " <> after_prefix
        new_col = anchor_col + 1 + String.length(path) + 1

        new_lines = List.replace_at(panel.input_lines, line, new_line)

        update_panel(state, fn p ->
          %{p | input_lines: new_lines, input_cursor: {line, new_col}, mention_completion: nil}
        end)
    end
  end

  @spec cancel_mention_completion(Minga.Editor.State.t()) :: Minga.Editor.State.t()
  defp cancel_mention_completion(state) do
    update_panel(state, fn p -> %{p | mention_completion: nil} end)
  end

  @spec handle_mention_char(Minga.Editor.State.t(), String.t()) :: Minga.Editor.State.t()
  defp handle_mention_char(state, " ") do
    # Space dismisses completion (user is done typing the path)
    state = update_panel(state, fn p -> %{p | mention_completion: nil} end)
    AgentCommands.input_char(state, " ")
  end

  defp handle_mention_char(state, char) do
    # Add char to both the input and the completion prefix
    state = AgentCommands.input_char(state, char)
    comp = state.agent.panel.mention_completion
    new_prefix = comp.prefix <> char

    update_panel(state, fn p ->
      %{p | mention_completion: FileMention.update_prefix(comp, new_prefix)}
    end)
  end

  @spec handle_mention_backspace(Minga.Editor.State.t()) :: Minga.Editor.State.t()
  defp handle_mention_backspace(state) do
    comp = state.agent.panel.mention_completion

    if comp.prefix == "" do
      # Backspace with empty prefix: delete the @ and cancel
      state = AgentCommands.input_backspace(state)
      update_panel(state, fn p -> %{p | mention_completion: nil} end)
    else
      # Shorten the prefix
      state = AgentCommands.input_backspace(state)
      new_prefix = String.slice(comp.prefix, 0..-2//1)

      update_panel(state, fn p ->
        %{p | mention_completion: FileMention.update_prefix(comp, new_prefix)}
      end)
    end
  end

  @spec list_project_files() :: [String.t()]
  defp list_project_files do
    root =
      try do
        case Minga.Project.root() do
          nil -> File.cwd!()
          r -> r
        end
      catch
        :exit, _ -> File.cwd!()
      end

    case Minga.FileFind.list_files(root) do
      {:ok, paths} -> paths
      {:error, _} -> []
    end
  end
end
