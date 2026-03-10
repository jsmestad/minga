defmodule Minga.Editor.State.Agent do
  @moduledoc """
  Agent-related editor state: session pid, status, panel UI, error, and spinner timer.

  All mutations go through functions in this module so callers never
  reach into the nested struct directly.
  """

  alias Minga.Agent.PanelState

  @typedoc "Agent status."
  @type status :: :idle | :thinking | :tool_executing | :error | nil

  @typedoc "Pending tool approval data."
  @type approval :: %{
          tool_call_id: String.t(),
          name: String.t(),
          args: map()
        }

  @typedoc "Agent sub-state."
  @type t :: %__MODULE__{
          session: pid() | nil,
          status: status(),
          panel: PanelState.t(),
          error: String.t() | nil,
          spinner_timer: {:ok, :timer.tref()} | nil,
          buffer: pid() | nil,
          pending_approval: approval() | nil,
          session_history: [pid()]
        }

  defstruct session: nil,
            status: nil,
            panel: PanelState.new(),
            error: nil,
            spinner_timer: nil,
            buffer: nil,
            pending_approval: nil,
            session_history: []

  # ── Status ──────────────────────────────────────────────────────────────────

  @doc "Sets the agent status."
  @spec set_status(t(), status()) :: t()
  def set_status(%__MODULE__{} = agent, status), do: %{agent | status: status}

  @doc "Sets the agent into an error state with a message."
  @spec set_error(t(), String.t()) :: t()
  def set_error(%__MODULE__{} = agent, message) do
    %{agent | status: :error, error: message}
  end

  # ── Session lifecycle ───────────────────────────────────────────────────────

  @doc "Stores the session pid and sets status to :idle. Archives the previous session."
  @spec set_session(t(), pid()) :: t()
  def set_session(%__MODULE__{session: nil} = agent, pid) when is_pid(pid) do
    %{agent | session: pid, status: :idle}
  end

  def set_session(%__MODULE__{session: old_pid} = agent, pid)
      when is_pid(pid) and is_pid(old_pid) do
    history = [old_pid | agent.session_history] |> Enum.uniq()
    %{agent | session: pid, status: :idle, session_history: history}
  end

  @doc "Sets the agent buffer pid."
  @spec set_buffer(t(), pid()) :: t()
  def set_buffer(%__MODULE__{} = agent, pid) when is_pid(pid) do
    %{agent | buffer: pid}
  end

  @doc "Returns all session pids (active + history), most recent first."
  @spec all_sessions(t()) :: [pid()]
  def all_sessions(%__MODULE__{session: nil} = agent), do: agent.session_history

  def all_sessions(%__MODULE__{} = agent) do
    [agent.session | agent.session_history]
  end

  @doc "Switches to a session from history, moving current to history."
  @spec switch_session(t(), pid()) :: t()
  def switch_session(%__MODULE__{session: nil} = agent, pid) when is_pid(pid) do
    history = List.delete(agent.session_history, pid)
    %{agent | session: pid, status: :idle, session_history: history}
  end

  def switch_session(%__MODULE__{session: current} = agent, pid)
      when is_pid(pid) and is_pid(current) do
    history =
      [current | agent.session_history]
      |> List.delete(pid)
      |> Enum.uniq()

    %{agent | session: pid, status: :idle, session_history: history}
  end

  @doc "Clears the session and resets status to :idle."
  @spec clear_session(t()) :: t()
  def clear_session(%__MODULE__{} = agent) do
    %{agent | session: nil, status: :idle}
  end

  # ── Panel delegation ────────────────────────────────────────────────────────
  # Thin wrappers that update the nested PanelState so callers avoid
  # `%{agent | panel: PanelState.foo(agent.panel, ...)}` boilerplate.

  @doc "Sets whether the agent input is focused."
  @spec focus_input(t(), boolean()) :: t()
  def focus_input(%__MODULE__{} = agent, focused) do
    %{agent | panel: PanelState.set_input_focused(agent.panel, focused)}
  end

  @doc "Scrolls the chat to the bottom and re-engages auto-scroll."
  @spec scroll_to_bottom(t()) :: t()
  def scroll_to_bottom(%__MODULE__{} = agent) do
    %{agent | panel: PanelState.scroll_to_bottom(agent.panel)}
  end

  @doc "Scrolls the chat to the top. Disengages auto-scroll."
  @spec scroll_to_top(t()) :: t()
  def scroll_to_top(%__MODULE__{} = agent) do
    %{agent | panel: PanelState.scroll_to_top(agent.panel)}
  end

  @doc "Scrolls the chat up by `amount` lines. Disengages auto-scroll."
  @spec scroll_up(t(), non_neg_integer()) :: t()
  def scroll_up(%__MODULE__{} = agent, amount) do
    %{agent | panel: PanelState.scroll_up(agent.panel, amount)}
  end

  @doc "Scrolls the chat down by `amount` lines. Disengages auto-scroll."
  @spec scroll_down(t(), non_neg_integer()) :: t()
  def scroll_down(%__MODULE__{} = agent, amount) do
    %{agent | panel: PanelState.scroll_down(agent.panel, amount)}
  end

  @doc "Sets the scroll offset to an absolute value."
  @spec set_scroll(t(), non_neg_integer()) :: t()
  def set_scroll(%__MODULE__{} = agent, offset) when is_integer(offset) and offset >= 0 do
    %{agent | panel: %{agent.panel | scroll_offset: offset, auto_scroll: false}}
  end

  @doc "Scrolls to bottom only if auto-scroll is engaged."
  @spec maybe_auto_scroll(t()) :: t()
  def maybe_auto_scroll(%__MODULE__{} = agent) do
    %{agent | panel: PanelState.maybe_auto_scroll(agent.panel)}
  end

  @doc "Re-engages auto-scroll and scrolls to bottom (e.g., new agent turn)."
  @spec engage_auto_scroll(t()) :: t()
  def engage_auto_scroll(%__MODULE__{} = agent) do
    %{agent | panel: PanelState.engage_auto_scroll(agent.panel)}
  end

  @doc "Advances the spinner animation frame."
  @spec tick_spinner(t()) :: t()
  def tick_spinner(%__MODULE__{} = agent) do
    %{agent | panel: PanelState.tick_spinner(agent.panel)}
  end

  @doc "Inserts a character into the agent input."
  @spec insert_char(t(), String.t()) :: t()
  def insert_char(%__MODULE__{} = agent, char) do
    %{agent | panel: PanelState.insert_char(agent.panel, char)}
  end

  @doc "Inserts pasted text into the agent input. Collapses multi-line pastes."
  @spec insert_paste(t(), String.t()) :: t()
  def insert_paste(%__MODULE__{} = agent, text) do
    %{agent | panel: PanelState.insert_paste(agent.panel, text)}
  end

  @doc "Toggles expand/collapse on the paste block at the current cursor line."
  @spec toggle_paste_expand(t()) :: t()
  def toggle_paste_expand(%__MODULE__{} = agent) do
    %{agent | panel: PanelState.toggle_paste_expand(agent.panel)}
  end

  @doc "Deletes the last character from the agent input."
  @spec delete_char(t()) :: t()
  def delete_char(%__MODULE__{} = agent) do
    %{agent | panel: PanelState.delete_char(agent.panel)}
  end

  @doc "Inserts a newline at the cursor position."
  @spec insert_newline(t()) :: t()
  def insert_newline(%__MODULE__{} = agent) do
    %{agent | panel: PanelState.insert_newline(agent.panel)}
  end

  @doc "Moves cursor up in the input. Returns `:at_top` if on the first line."
  @spec move_cursor_up(t()) :: t() | :at_top
  def move_cursor_up(%__MODULE__{} = agent) do
    case PanelState.move_cursor_up(agent.panel) do
      :at_top -> :at_top
      panel -> %{agent | panel: panel}
    end
  end

  @doc "Moves cursor down in the input. Returns `:at_bottom` if on the last line."
  @spec move_cursor_down(t()) :: t() | :at_bottom
  def move_cursor_down(%__MODULE__{} = agent) do
    case PanelState.move_cursor_down(agent.panel) do
      :at_bottom -> :at_bottom
      panel -> %{agent | panel: panel}
    end
  end

  @doc "Recalls the previous prompt from history."
  @spec history_prev(t()) :: t()
  def history_prev(%__MODULE__{} = agent) do
    %{agent | panel: PanelState.history_prev(agent.panel)}
  end

  @doc "Recalls the next prompt from history."
  @spec history_next(t()) :: t()
  def history_next(%__MODULE__{} = agent) do
    %{agent | panel: PanelState.history_next(agent.panel)}
  end

  # ── Tool approval ──────────────────────────────────────────────────────────

  @doc "Sets a pending tool approval."
  @spec set_pending_approval(t(), approval()) :: t()
  def set_pending_approval(%__MODULE__{} = agent, approval) when is_map(approval) do
    %{agent | pending_approval: approval}
  end

  @doc "Clears the pending tool approval."
  @spec clear_pending_approval(t()) :: t()
  def clear_pending_approval(%__MODULE__{} = agent) do
    %{agent | pending_approval: nil}
  end

  @doc "Clears the chat display (visual reset, history preserved)."
  @spec clear_display(t(), non_neg_integer()) :: t()
  def clear_display(%__MODULE__{} = agent, message_count) do
    %{agent | panel: PanelState.clear_display(agent.panel, message_count)}
  end

  @doc "Clears the input and scrolls to the bottom."
  @spec clear_input_and_scroll(t()) :: t()
  def clear_input_and_scroll(%__MODULE__{} = agent) do
    %{agent | panel: agent.panel |> PanelState.clear_input() |> PanelState.scroll_to_bottom()}
  end

  @doc "Toggles the panel visibility."
  @spec toggle_panel(t()) :: t()
  def toggle_panel(%__MODULE__{} = agent) do
    %{agent | panel: PanelState.toggle(agent.panel)}
  end

  # ── Panel config ────────────────────────────────────────────────────────────

  @doc "Sets the thinking level."
  @spec set_thinking_level(t(), String.t()) :: t()
  def set_thinking_level(%__MODULE__{} = agent, level) do
    %{agent | panel: %{agent.panel | thinking_level: level}}
  end

  @doc "Sets the provider name."
  @spec set_provider_name(t(), String.t()) :: t()
  def set_provider_name(%__MODULE__{} = agent, provider) do
    %{agent | panel: %{agent.panel | provider_name: provider}}
  end

  @doc "Sets the model name."
  @spec set_model_name(t(), String.t()) :: t()
  def set_model_name(%__MODULE__{} = agent, model) do
    %{agent | panel: %{agent.panel | model_name: model}}
  end

  # ── Spinner timer ───────────────────────────────────────────────────────────

  @doc "Starts the spinner timer if not already running."
  @spec start_spinner_timer(t()) :: t()
  def start_spinner_timer(%__MODULE__{spinner_timer: nil} = agent) do
    timer = :timer.send_interval(100, :agent_spinner_tick)
    %{agent | spinner_timer: timer}
  end

  def start_spinner_timer(%__MODULE__{} = agent), do: agent

  @doc "Stops the spinner timer if running."
  @spec stop_spinner_timer(t()) :: t()
  def stop_spinner_timer(%__MODULE__{spinner_timer: nil} = agent), do: agent

  def stop_spinner_timer(%__MODULE__{spinner_timer: {:ok, ref}} = agent) do
    :timer.cancel(ref)
    %{agent | spinner_timer: nil}
  end

  # ── Queries ─────────────────────────────────────────────────────────────────

  @doc "Returns true if the panel is visible."
  @spec visible?(t()) :: boolean()
  def visible?(%__MODULE__{panel: panel}), do: panel.visible

  @doc "Returns true if the agent input is focused."
  @spec input_focused?(t()) :: boolean()
  def input_focused?(%__MODULE__{panel: panel}), do: panel.input_focused

  @doc "Returns true if the agent is actively working."
  @spec busy?(t()) :: boolean()
  def busy?(%__MODULE__{status: s}) when s in [:thinking, :tool_executing], do: true
  def busy?(%__MODULE__{}), do: false
end
