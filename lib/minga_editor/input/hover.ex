defmodule MingaEditor.Input.Hover do
  @moduledoc """
  Input handler for the hover popup.

  When a hover popup is visible, this handler intercepts keys:

  - **K** (when not focused): focuses into the hover for scrolling
  - **j/k** (when focused): scrolls the hover content
  - **q/Escape** (when focused): dismisses the hover
  - **Any other key** (when not focused): dismisses the hover and passes through

  Follows the LazyVim pattern: press K once to show hover, press K
  again to focus into it for scrolling, press q to dismiss.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  alias MingaEditor.HoverPopup
  alias MingaEditor.State, as: EditorState

  # Escape codepoint from the port protocol
  @key_escape 27

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(%{shell_state: %{hover_popup: nil}} = state, _codepoint, _modifiers) do
    {:passthrough, state}
  end

  # K pressed while hover is visible but not focused: focus into it.
  # The frontend sends uppercase K as codepoint ?K (75) with no shift modifier,
  # matching how normal.ex binds {?K, 0} to :hover.
  def handle_key(%{shell_state: %{hover_popup: %HoverPopup{focused: false}}} = state, ?K, 0) do
    {:handled,
     EditorState.set_hover_popup(state, HoverPopup.focus(state.shell_state.hover_popup))}
  end

  # When focused, j scrolls down
  def handle_key(%{shell_state: %{hover_popup: %HoverPopup{focused: true}}} = state, ?j, 0) do
    {:handled,
     EditorState.set_hover_popup(state, HoverPopup.scroll_down(state.shell_state.hover_popup))}
  end

  # When focused, k scrolls up
  def handle_key(%{shell_state: %{hover_popup: %HoverPopup{focused: true}}} = state, ?k, 0) do
    {:handled,
     EditorState.set_hover_popup(state, HoverPopup.scroll_up(state.shell_state.hover_popup))}
  end

  # When focused, q or Escape dismisses
  def handle_key(%{shell_state: %{hover_popup: %HoverPopup{focused: true}}} = state, ?q, 0) do
    {:handled, EditorState.dismiss_hover_popup(state)}
  end

  def handle_key(
        %{shell_state: %{hover_popup: %HoverPopup{focused: true}}} = state,
        @key_escape,
        _mods
      ) do
    {:handled, EditorState.dismiss_hover_popup(state)}
  end

  # When focused, any other key dismisses and passes through
  def handle_key(%{shell_state: %{hover_popup: %HoverPopup{focused: true}}} = state, _cp, _mods) do
    {:passthrough, EditorState.dismiss_hover_popup(state)}
  end

  # Not focused: any key dismisses and passes through
  def handle_key(%{shell_state: %{hover_popup: %HoverPopup{focused: false}}} = state, _cp, _mods) do
    {:passthrough, EditorState.dismiss_hover_popup(state)}
  end

  # ── Mouse handling ──────────────────────────────────────────────────────

  @impl true
  @spec handle_mouse(
          state(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: MingaEditor.Input.Handler.result()

  def handle_mouse(
        %{shell_state: %{hover_popup: nil}} = state,
        _row,
        _col,
        _btn,
        _mods,
        _type,
        _cc
      ) do
    {:passthrough, state}
  end

  # Scroll wheel when focused: scroll the hover content
  def handle_mouse(
        %{shell_state: %{hover_popup: %HoverPopup{focused: true}}} = state,
        _r,
        _c,
        :wheel_down,
        _m,
        _t,
        _cc
      ) do
    {:handled,
     EditorState.set_hover_popup(state, HoverPopup.scroll_down(state.shell_state.hover_popup))}
  end

  def handle_mouse(
        %{shell_state: %{hover_popup: %HoverPopup{focused: true}}} = state,
        _r,
        _c,
        :wheel_up,
        _m,
        _t,
        _cc
      ) do
    {:handled,
     EditorState.set_hover_popup(state, HoverPopup.scroll_up(state.shell_state.hover_popup))}
  end

  # Any click dismisses hover
  def handle_mouse(
        %{shell_state: %{hover_popup: %HoverPopup{}}} = state,
        _r,
        _c,
        :left,
        _m,
        :press,
        _cc
      ) do
    {:passthrough, EditorState.dismiss_hover_popup(state)}
  end

  def handle_mouse(state, _row, _col, _btn, _mods, _type, _cc) do
    {:passthrough, state}
  end
end
