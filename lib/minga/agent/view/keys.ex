defmodule Minga.Agent.View.Keys do
  @moduledoc """
  Input handler for the full-screen agentic view.

  Active only when `state.agentic.active` is true. Dispatches keys based on
  `state.agentic.focus` (:chat or :file_viewer) and whether the chat input
  is focused (`state.agent.panel.input_focused`).

  ## Doom Emacs keymap conventions

  The agentic view is a read-only special buffer, following Doom/Evil
  conventions for key assignment:

  - **Sacred vim motions** (j/k/gg/G/Ctrl-d/u/ etc.) keep their meaning
  - **Editing keys** (i/a/o/s/y/q) are repurposed since editing is not possible
  - **`z` prefix** for fold/collapse (vim fold convention)
  - **`]`/`[` prefix** for next/prev navigation (Doom bracket convention)
  - **`g` prefix** for go-to actions (vim g-prefix convention)
  - **SPC** always delegates to the mode FSM for leader/which-key

  See `docs/AGENTIC-KEYMAP.md` for the full reference.
  """

  @behaviour Minga.Input.Handler

  import Bitwise

  alias Minga.Agent.Session
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

  # SPC prefix: delegate to mode FSM so leader/which-key work,
  # but NOT when the chat input is focused (space is a typeable character).
  def handle_key(
        %{agent: %{panel: %{input_focused: false}}} = state,
        @space,
        mods
      )
      when band(mods, @ctrl) == 0 do
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

  # ── Chat navigation mode ────────────────────────────────────────────────────

  @spec handle_chat_nav(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()

  # --- Prefix dispatch: if a prefix is pending, route to prefix handler ---

  defp handle_chat_nav(%{agentic: %{pending_prefix: prefix}} = state, cp, mods)
       when prefix != nil do
    state = update_agentic(state, &ViewState.clear_prefix/1)
    handle_prefix(state, prefix, cp, mods, :chat)
  end

  # --- Prefix starters ---

  # g: start g-prefix (gg, gf)
  defp handle_chat_nav(state, ?g, _mods) do
    update_agentic(state, &ViewState.set_prefix(&1, :g))
  end

  # z: start z-prefix (za, zA, zo, zc, zM, zR)
  defp handle_chat_nav(state, ?z, _mods) do
    update_agentic(state, &ViewState.set_prefix(&1, :z))
  end

  # ]: start bracket-next prefix (]m, ]c, ]t)
  defp handle_chat_nav(state, ?], _mods) do
    update_agentic(state, &ViewState.set_prefix(&1, :bracket_next))
  end

  # [: start bracket-prev prefix ([m, [c, [t)
  defp handle_chat_nav(state, ?[, _mods) do
    update_agentic(state, &ViewState.set_prefix(&1, :bracket_prev))
  end

  # --- View management ---

  # q or Escape: close the agentic view
  defp handle_chat_nav(state, cp, _mods) when cp in [?q, @escape] do
    AgentCommands.toggle_agentic_view(state)
  end

  # Tab: switch focus to the file viewer
  defp handle_chat_nav(state, @tab, _mods) do
    update_agentic(state, &ViewState.set_focus(&1, :file_viewer))
  end

  # --- Input focus (repurposed insert-mode keys) ---

  # i / a / Enter: focus the input field
  defp handle_chat_nav(state, cp, _mods) when cp in [?i, ?a, @enter] do
    update_agent(state, &AgentState.focus_input(&1, true))
  end

  # --- Scrolling (sacred vim motions) ---

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

  # --- Repurposed editing keys ---

  # o: toggle tool/thinking collapse at cursor (magit precedent, alias for za)
  defp handle_chat_nav(state, ?o, _mods) do
    toggle_collapse_at_cursor(state)
  end

  # y: copy code block at cursor to clipboard (yank = copy semantic parallel)
  # Stubbed until #177 provides line-to-message mapping
  defp handle_chat_nav(state, ?y, _mods), do: state

  # Y: copy full message at cursor to clipboard
  # Stubbed until #177 provides line-to-message mapping
  defp handle_chat_nav(state, ?Y, _mods), do: state

  # s: session switcher (magit precedent; stubbed until #175)
  defp handle_chat_nav(state, ?s, _mods), do: state

  # --- Panel resize ---

  # }: grow chat panel width
  defp handle_chat_nav(state, ?}, _mods) do
    update_agentic(state, &ViewState.grow_chat/1)
  end

  # {: shrink chat panel width
  defp handle_chat_nav(state, ?{, _mods) do
    update_agentic(state, &ViewState.shrink_chat/1)
  end

  # =: reset panel split to default
  defp handle_chat_nav(state, ?=, _mods) do
    update_agentic(state, &ViewState.reset_split/1)
  end

  # --- Help ---

  # ?: help overlay (stubbed until #173)
  defp handle_chat_nav(state, ??, _mods), do: state

  # --- Catch-all ---

  defp handle_chat_nav(state, _cp, _mods), do: state

  # ── File viewer navigation ──────────────────────────────────────────────────

  @spec handle_viewer_nav(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()

  # --- Prefix dispatch ---

  defp handle_viewer_nav(%{agentic: %{pending_prefix: prefix}} = state, cp, mods)
       when prefix != nil do
    state = update_agentic(state, &ViewState.clear_prefix/1)
    handle_prefix(state, prefix, cp, mods, :file_viewer)
  end

  # --- Prefix starters ---

  defp handle_viewer_nav(state, ?g, _mods) do
    update_agentic(state, &ViewState.set_prefix(&1, :g))
  end

  defp handle_viewer_nav(state, ?z, _mods) do
    update_agentic(state, &ViewState.set_prefix(&1, :z))
  end

  defp handle_viewer_nav(state, ?], _mods) do
    update_agentic(state, &ViewState.set_prefix(&1, :bracket_next))
  end

  defp handle_viewer_nav(state, ?[, _mods) do
    update_agentic(state, &ViewState.set_prefix(&1, :bracket_prev))
  end

  # --- View management ---

  # Tab: switch focus back to chat
  defp handle_viewer_nav(state, @tab, _mods) do
    update_agentic(state, &ViewState.set_focus(&1, :chat))
  end

  # q or Escape: close the agentic view
  defp handle_viewer_nav(state, cp, _mods) when cp in [?q, @escape] do
    AgentCommands.toggle_agentic_view(state)
  end

  # --- Scrolling ---

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

  # G: scroll to bottom
  defp handle_viewer_nav(state, ?G, _mods) do
    update_agentic(state, &ViewState.scroll_viewer_to_bottom/1)
  end

  # --- Panel resize ---

  defp handle_viewer_nav(state, ?}, _mods) do
    update_agentic(state, &ViewState.grow_chat/1)
  end

  defp handle_viewer_nav(state, ?{, _mods) do
    update_agentic(state, &ViewState.shrink_chat/1)
  end

  defp handle_viewer_nav(state, ?=, _mods) do
    update_agentic(state, &ViewState.reset_split/1)
  end

  # --- Help ---

  defp handle_viewer_nav(state, ??, _mods), do: state

  # --- Catch-all ---

  defp handle_viewer_nav(state, _cp, _mods), do: state

  # ── Prefix handlers ─────────────────────────────────────────────────────────

  @spec handle_prefix(
          EditorState.t(),
          ViewState.prefix(),
          non_neg_integer(),
          non_neg_integer(),
          :chat | :file_viewer
        ) ::
          EditorState.t()

  # --- g prefix ---

  # gg: scroll to top
  defp handle_prefix(state, :g, ?g, _mods, :chat) do
    update_agent(state, &AgentState.scroll_to_top/1)
  end

  defp handle_prefix(state, :g, ?g, _mods, :file_viewer) do
    update_agentic(state, &ViewState.scroll_viewer_to_top/1)
  end

  # gf: open code block in editor buffer (stubbed until #189)
  defp handle_prefix(state, :g, ?f, _mods, :chat), do: state

  # g + unrecognized: cancel prefix and process the key normally
  defp handle_prefix(state, :g, cp, mods, :chat), do: handle_chat_nav(state, cp, mods)
  defp handle_prefix(state, :g, cp, mods, :file_viewer), do: handle_viewer_nav(state, cp, mods)

  # --- z prefix (folds/collapse) ---

  # za: toggle collapse at cursor
  defp handle_prefix(state, :z, ?a, _mods, _context) do
    toggle_collapse_at_cursor(state)
  end

  # zA: toggle ALL collapses
  defp handle_prefix(state, :z, ?A, _mods, _context) do
    toggle_all_collapses(state)
  end

  # zo: expand at cursor (stubbed until #180 provides per-item collapse)
  defp handle_prefix(state, :z, ?o, _mods, _context), do: state

  # zc: collapse at cursor (stubbed until #180 provides per-item collapse)
  defp handle_prefix(state, :z, ?c, _mods, _context), do: state

  # zM: collapse all
  defp handle_prefix(state, :z, ?M, _mods, _context) do
    toggle_all_collapses(state)
  end

  # zR: expand all
  defp handle_prefix(state, :z, ?R, _mods, _context) do
    toggle_all_collapses(state)
  end

  # z + unrecognized: cancel prefix, process key normally
  defp handle_prefix(state, :z, cp, mods, :chat), do: handle_chat_nav(state, cp, mods)
  defp handle_prefix(state, :z, cp, mods, :file_viewer), do: handle_viewer_nav(state, cp, mods)

  # --- ] prefix (next item) ---

  # ]m: next message (stubbed until #177 line-to-message mapping)
  defp handle_prefix(state, :bracket_next, ?m, _mods, _context), do: state

  # ]c: next code block (stubbed until #177)
  defp handle_prefix(state, :bracket_next, ?c, _mods, _context), do: state

  # ]t: next tool call (stubbed until #177)
  defp handle_prefix(state, :bracket_next, ?t, _mods, _context), do: state

  # ] + unrecognized: cancel prefix, process key normally
  defp handle_prefix(state, :bracket_next, cp, mods, :chat), do: handle_chat_nav(state, cp, mods)

  defp handle_prefix(state, :bracket_next, cp, mods, :file_viewer),
    do: handle_viewer_nav(state, cp, mods)

  # --- [ prefix (prev item) ---

  # [m: prev message (stubbed until #177)
  defp handle_prefix(state, :bracket_prev, ?m, _mods, _context), do: state

  # [c: prev code block (stubbed until #177)
  defp handle_prefix(state, :bracket_prev, ?c, _mods, _context), do: state

  # [t: prev tool call (stubbed until #177)
  defp handle_prefix(state, :bracket_prev, ?t, _mods, _context), do: state

  # [ + unrecognized: cancel prefix, process key normally
  defp handle_prefix(state, :bracket_prev, cp, mods, :chat), do: handle_chat_nav(state, cp, mods)

  defp handle_prefix(state, :bracket_prev, cp, mods, :file_viewer),
    do: handle_viewer_nav(state, cp, mods)

  # ── Collapse helpers ────────────────────────────────────────────────────────

  @spec toggle_collapse_at_cursor(EditorState.t()) :: EditorState.t()
  defp toggle_collapse_at_cursor(state) do
    # Toggle all for now; per-item toggle requires line-to-message mapping (#177)
    toggle_all_collapses(state)
  end

  @spec toggle_all_collapses(EditorState.t()) :: EditorState.t()
  defp toggle_all_collapses(state) do
    if state.agent.session do
      Session.toggle_all_tool_collapses(state.agent.session)
    end

    state
  end

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
