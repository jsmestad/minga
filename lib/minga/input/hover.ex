defmodule Minga.Input.Hover do
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

  @behaviour Minga.Input.Handler

  alias Minga.Editor.HoverPopup
  alias Minga.Editor.State, as: EditorState

  # Escape codepoint from the port protocol
  @key_escape 27

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()
  def handle_key(%{hover_popup: nil} = state, _codepoint, _modifiers) do
    {:passthrough, state}
  end

  # K pressed while hover is visible but not focused: focus into it.
  # The frontend sends uppercase K as codepoint ?K (75) with no shift modifier,
  # matching how normal.ex binds {?K, 0} to :hover.
  def handle_key(%{hover_popup: %HoverPopup{focused: false}} = state, ?K, 0) do
    {:handled, %{state | hover_popup: HoverPopup.focus(state.hover_popup)}}
  end

  # When focused, j scrolls down
  def handle_key(%{hover_popup: %HoverPopup{focused: true}} = state, ?j, 0) do
    {:handled, %{state | hover_popup: HoverPopup.scroll_down(state.hover_popup)}}
  end

  # When focused, k scrolls up
  def handle_key(%{hover_popup: %HoverPopup{focused: true}} = state, ?k, 0) do
    {:handled, %{state | hover_popup: HoverPopup.scroll_up(state.hover_popup)}}
  end

  # When focused, q or Escape dismisses
  def handle_key(%{hover_popup: %HoverPopup{focused: true}} = state, ?q, 0) do
    {:handled, %{state | hover_popup: nil}}
  end

  def handle_key(%{hover_popup: %HoverPopup{focused: true}} = state, @key_escape, _mods) do
    {:handled, %{state | hover_popup: nil}}
  end

  # When focused, any other key dismisses and passes through
  def handle_key(%{hover_popup: %HoverPopup{focused: true}} = state, _cp, _mods) do
    {:passthrough, %{state | hover_popup: nil}}
  end

  # Not focused: any key dismisses and passes through
  def handle_key(%{hover_popup: %HoverPopup{focused: false}} = state, _cp, _mods) do
    {:passthrough, %{state | hover_popup: nil}}
  end
end
