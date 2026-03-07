defmodule Minga.Agent.View.Keys do
  @moduledoc """
  Input handler for the full-screen agentic view.

  Active only when `state.agentic.active` is true. Dispatches keys based on
  `state.agentic.focus` (:chat or :file_viewer) and whether the chat input
  is focused (`state.agent.panel.input_focused`).

  Focus model:

  - **Chat, input focused** (`input_focused: true`): printable chars go to the
    input field; Backspace deletes; Enter/Ctrl+C submits; Esc unfocuses.
  - **Chat, navigating** (`input_focused: false`): j/k scroll the chat; Ctrl-d/u
    half-page; gg/G top/bottom; i/a/Enter focus the input; o toggles tool
    collapse; Tab switches focus to the file viewer; q closes the view.
  - **File viewer**: j/k scroll the buffer; Ctrl-d/u half-page; gg/G top/bottom;
    Tab switches focus back to chat.
  - **SPC prefix**: always delegated to the mode FSM so which-key and leader
    sequences work normally.
  """

  @behaviour Minga.Input.Handler

  import Bitwise

  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Port.Protocol

  @ctrl Protocol.mod_ctrl()
  @alt Protocol.mod_alt()
  @space 32
  @escape 27
  @tab 9
  @enter 13
  @backspace 127

  # ── Handler behaviour ───────────────────────────────────────────────────────

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()

  # Only active when agentic view is open.
  def handle_key(%{agentic: %{active: false}} = state, _cp, _mods) do
    {:passthrough, state}
  end

  # SPC prefix — always delegate to the mode FSM so leader/which-key work.
  def handle_key(state, @space, mods) when band(mods, @ctrl) == 0 do
    {:passthrough, state}
  end

  # Route based on focus.
  def handle_key(
        %{agentic: %{focus: :chat}, agent: %{panel: %{input_focused: true}}} = state,
        cp,
        mods
      ) do
    {:handled, handle_chat_input(state, cp, mods)}
  end

  def handle_key(%{agentic: %{focus: :chat}} = state, cp, mods) do
    {:handled, handle_chat_nav(state, cp, mods)}
  end

  def handle_key(%{agentic: %{focus: :file_viewer}} = state, cp, mods) do
    {:handled, handle_viewer_nav(state, cp, mods)}
  end

  # ── Chat input mode (input_focused: true) ───────────────────────────────────

  @spec handle_chat_input(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()

  defp handle_chat_input(state, @escape, _mods) do
    update_agent(state, &AgentState.focus_input(&1, false))
  end

  defp handle_chat_input(state, @backspace, _mods) do
    AgentCommands.input_backspace(state)
  end

  defp handle_chat_input(state, @enter, _mods) do
    AgentCommands.submit_prompt(state)
  end

  defp handle_chat_input(state, ?c, mods) when band(mods, @ctrl) != 0 do
    AgentCommands.submit_prompt(state)
  end

  defp handle_chat_input(state, ?d, mods) when band(mods, @ctrl) != 0 do
    scroll_chat_down_half(state)
  end

  defp handle_chat_input(state, ?u, mods) when band(mods, @ctrl) != 0 do
    scroll_chat_up_half(state)
  end

  defp handle_chat_input(state, cp, mods)
       when cp >= 32 and band(mods, @ctrl) == 0 and band(mods, @alt) == 0 do
    AgentCommands.input_char(state, <<cp::utf8>>)
  end

  defp handle_chat_input(state, _cp, _mods), do: state

  # ── Chat navigation mode (input_focused: false) ─────────────────────────────

  @spec handle_chat_nav(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()

  # q or Escape: close the agentic view
  defp handle_chat_nav(state, cp, _mods) when cp in [?q, @escape] do
    AgentCommands.toggle_agentic_view(state)
  end

  # i / a / Enter: focus the input field
  defp handle_chat_nav(state, cp, _mods) when cp in [?i, ?a, @enter] do
    update_agent(state, &AgentState.focus_input(&1, true))
  end

  # Tab: switch focus to the file viewer
  defp handle_chat_nav(state, @tab, _mods) do
    update_agentic(state, &ViewState.set_focus(&1, :file_viewer))
  end

  # j: scroll chat down 1 line
  defp handle_chat_nav(state, ?j, _mods) do
    update_agent(state, &AgentState.scroll_down(&1, 1))
  end

  # k: scroll chat up 1 line
  defp handle_chat_nav(state, ?k, _mods) do
    update_agent(state, &AgentState.scroll_up(&1, 1))
  end

  # Ctrl-d: scroll chat down half page
  defp handle_chat_nav(state, ?d, mods) when band(mods, @ctrl) != 0 do
    scroll_chat_down_half(state)
  end

  # Ctrl-u: scroll chat up half page
  defp handle_chat_nav(state, ?u, mods) when band(mods, @ctrl) != 0 do
    scroll_chat_up_half(state)
  end

  # G: scroll to bottom
  defp handle_chat_nav(state, ?G, _mods) do
    update_agent(state, &AgentState.scroll_to_bottom/1)
  end

  # o: toggle tool call collapse — placeholder; full implementation requires
  # mapping scroll offset to message index (see ticket #133 risks section).
  defp handle_chat_nav(state, ?o, _mods) do
    state
  end

  defp handle_chat_nav(state, _cp, _mods), do: state

  # ── File viewer navigation ───────────────────────────────────────────────────

  @spec handle_viewer_nav(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()

  # Tab: switch focus back to chat
  defp handle_viewer_nav(state, @tab, _mods) do
    update_agentic(state, &ViewState.set_focus(&1, :chat))
  end

  # q or Escape: close the agentic view
  defp handle_viewer_nav(state, cp, _mods) when cp in [?q, @escape] do
    AgentCommands.toggle_agentic_view(state)
  end

  # j: scroll file viewer down 1 line
  defp handle_viewer_nav(state, ?j, _mods) do
    update_agentic(state, &ViewState.scroll_viewer_down(&1, 1))
  end

  # k: scroll file viewer up 1 line
  defp handle_viewer_nav(state, ?k, _mods) do
    update_agentic(state, &ViewState.scroll_viewer_up(&1, 1))
  end

  # Ctrl-d: scroll file viewer down half page
  defp handle_viewer_nav(state, ?d, mods) when band(mods, @ctrl) != 0 do
    amount = viewer_half_page(state)
    update_agentic(state, &ViewState.scroll_viewer_down(&1, amount))
  end

  # Ctrl-u: scroll file viewer up half page
  defp handle_viewer_nav(state, ?u, mods) when band(mods, @ctrl) != 0 do
    amount = viewer_half_page(state)
    update_agentic(state, &ViewState.scroll_viewer_up(&1, amount))
  end

  # gg: scroll to top (first press — we handle single-key for simplicity)
  defp handle_viewer_nav(state, ?g, _mods) do
    update_agentic(state, &ViewState.scroll_viewer_to_top/1)
  end

  # G: scroll to bottom (approximate — jump to a large offset; renderer clamps)
  defp handle_viewer_nav(state, ?G, _mods) do
    update_agentic(state, &ViewState.scroll_viewer_to_bottom/1)
  end

  defp handle_viewer_nav(state, _cp, _mods), do: state

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec scroll_chat_down_half(EditorState.t()) :: EditorState.t()
  defp scroll_chat_down_half(state) do
    amount = chat_half_page(state)
    update_agent(state, &AgentState.scroll_down(&1, amount))
  end

  @spec scroll_chat_up_half(EditorState.t()) :: EditorState.t()
  defp scroll_chat_up_half(state) do
    amount = chat_half_page(state)
    update_agent(state, &AgentState.scroll_up(&1, amount))
  end

  @spec chat_half_page(EditorState.t()) :: pos_integer()
  defp chat_half_page(state) do
    max(div(state.viewport.rows, 2), 1)
  end

  @spec viewer_half_page(EditorState.t()) :: pos_integer()
  defp viewer_half_page(state) do
    max(div(state.viewport.rows, 2), 1)
  end

  @spec update_agent(EditorState.t(), (AgentState.t() -> AgentState.t())) :: EditorState.t()
  defp update_agent(state, fun) do
    %{state | agent: fun.(state.agent)}
  end

  @spec update_agentic(EditorState.t(), (ViewState.t() -> ViewState.t())) ::
          EditorState.t()
  defp update_agentic(state, fun) do
    %{state | agentic: fun.(state.agentic)}
  end
end
