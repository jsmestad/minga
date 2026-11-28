defmodule MingaEditor.Input.Hover do
  @moduledoc """
  Input handler for the hover popup.

  When a hover popup is visible, this handler intercepts keys:

  - **K** (when not focused): focuses into the hover for scrolling
  - **j/k** or **Ctrl-D/Ctrl-U** (when focused): scrolls the hover content
  - **y** (when focused): yanks the whole displayed document
  - **q/Escape** (when focused): dismisses the hover
  - **Any other key** (when not focused): dismisses the hover and passes through

  Follows the LazyVim pattern: press K once to show hover, press K
  again to focus into it for scrolling, press q to dismiss.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  alias MingaEditor.Commands.Helpers
  alias MingaEditor.HoverPopup

  # Escape and Enter codepoints from the port protocol
  @key_escape 27
  @key_enter 13
  @key_tab 9
  @shift 0x01
  @control 0x02
  # Control, Alt and Command: a key held with any of them is a chord.
  @chord_mods 0x0E

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(%{shell_runtime: %{state: %{hover_popup: nil}}} = state, _codepoint, _modifiers) do
    {:passthrough, state}
  end

  # The normal-state trie owns g. and all other g commands. Keep the offer alive only for g.
  def handle_key(
        %{
          shell_runtime: %{state: %{hover_popup: %HoverPopup{code_source: source}}},
          workspace: %{editing: %{mode: :normal, mode_state: %Minga.Mode.State{prefix_keys: []}}}
        } = state,
        ?g,
        0
      )
      when source != nil,
      do: {:passthrough, state}

  def handle_key(
        %{
          shell_runtime: %{state: %{hover_popup: %HoverPopup{code_source: source}}},
          workspace: %{
            editing: %{mode: :normal, mode_state: %Minga.Mode.State{prefix_keys: ["g"]}}
          }
        } = state,
        codepoint,
        mods
      )
      when source != nil do
    if codepoint == ?. and mods == 0,
      do: {:passthrough, state},
      else: {:passthrough, MingaEditor.Shell.Traditional.HoverPopupWorkflow.dismiss(state)}
  end

  # K pressed while hover is visible but not focused: focus into it.
  # The frontend sends uppercase K as codepoint ?K (75) with no shift modifier,
  # matching how normal.ex binds {?K, 0} to :hover.
  def handle_key(
        %{shell_runtime: %{state: %{hover_popup: %MingaEditor.HoverPopup{focused: false}}}} =
          state,
        ?K,
        0
      ) do
    {:handled, MingaEditor.Shell.Traditional.HoverPopupWorkflow.focus(state)}
  end

  def handle_key(
        %{shell_runtime: %{state: %{hover_popup: %HoverPopup{focused: true}}}} = state,
        codepoint,
        modifiers
      )
      when (codepoint == ?j and modifiers == 0) or (codepoint == ?d and modifiers == @control) do
    {:handled, MingaEditor.Shell.Traditional.HoverPopupWorkflow.scroll_down(state)}
  end

  def handle_key(
        %{shell_runtime: %{state: %{hover_popup: %HoverPopup{focused: true}}}} = state,
        codepoint,
        modifiers
      )
      when (codepoint == ?k and modifiers == 0) or (codepoint == ?u and modifiers == @control) do
    {:handled, MingaEditor.Shell.Traditional.HoverPopupWorkflow.scroll_up(state)}
  end

  def handle_key(
        %{shell_runtime: %{state: %{hover_popup: %HoverPopup{focused: true} = popup}}} = state,
        ?y,
        0
      ) do
    case HoverPopup.copy_text(popup) do
      "" -> {:handled, state}
      text -> {:handled, Helpers.put_register(state, text, :yank)}
    end
  end

  def handle_key(
        %{shell_runtime: %{state: %{hover_popup: %HoverPopup{focused: true, links: links}}}} =
          state,
        @key_tab,
        mods
      )
      when tuple_size(links) > 0 and mods in [0, @shift] do
    direction = if mods == @shift, do: :previous, else: :next
    {:handled, MingaEditor.Shell.Traditional.HoverPopupWorkflow.select_link(state, direction)}
  end

  def handle_key(
        %{
          shell_runtime: %{
            state: %{hover_popup: %HoverPopup{focused: true, selected_link: id, offer_id: offer}}
          }
        } = state,
        @key_enter,
        mods
      )
      when id != nil do
    if Bitwise.band(mods, @chord_mods) == 0,
      do:
        {:handled,
         MingaEditor.Shell.Traditional.HoverPopupWorkflow.activate_offer(
           state,
           offer,
           {:link, id}
         )},
      else: {:handled, state}
  end

  # An attributed code hover offers its conversation immediately. Other popups require focus.
  def handle_key(
        %{
          shell_runtime: %{
            state: %{
              hover_popup: %HoverPopup{focused: focused, code_source: source, open_action: action}
            }
          }
        } = state,
        @key_enter,
        mods
      )
      when action != nil and (focused or source != nil) and Bitwise.band(mods, @chord_mods) == 0 do
    {:handled, MingaEditor.Shell.Traditional.HoverPopupWorkflow.activate_open(state)}
  end

  # Enter held with Control, Alt or Command neither accepts nor dismisses: Esc then Enter that arrive together are
  # Alt+Enter in a terminal without enhanced key reporting.
  def handle_key(
        %{
          shell_runtime: %{
            state: %{
              hover_popup: %HoverPopup{focused: focused, code_source: source, open_action: action}
            }
          }
        } = state,
        @key_enter,
        _mods
      )
      when action != nil and (focused or source != nil) do
    {:handled, state}
  end

  # When focused, o toggles an expandable popup (e.g. full vs truncated thinking).
  def handle_key(
        %{shell_runtime: %{state: %{hover_popup: %HoverPopup{focused: true} = popup}}} = state,
        ?o,
        0
      ) do
    if HoverPopup.expandable?(popup) do
      {:handled, MingaEditor.Shell.Traditional.HoverPopupWorkflow.toggle_expand(state)}
    else
      {:passthrough, MingaEditor.Shell.Traditional.HoverPopupWorkflow.dismiss(state)}
    end
  end

  # When focused, q or Escape dismisses
  def handle_key(
        %{shell_runtime: %{state: %{hover_popup: %MingaEditor.HoverPopup{focused: true}}}} = state,
        ?q,
        0
      ) do
    {:handled, MingaEditor.Shell.Traditional.HoverPopupWorkflow.dismiss(state)}
  end

  def handle_key(
        %{shell_runtime: %{state: %{hover_popup: %HoverPopup{focused: true}}}} = state,
        @key_escape,
        _mods
      ) do
    {:handled, MingaEditor.Shell.Traditional.HoverPopupWorkflow.dismiss(state)}
  end

  # When focused, any other key dismisses and passes through
  def handle_key(
        %{shell_runtime: %{state: %{hover_popup: %MingaEditor.HoverPopup{focused: true}}}} = state,
        _cp,
        _mods
      ) do
    {:passthrough, MingaEditor.Shell.Traditional.HoverPopupWorkflow.dismiss(state)}
  end

  # Not focused: any key dismisses and passes through
  def handle_key(
        %{shell_runtime: %{state: %{hover_popup: %MingaEditor.HoverPopup{focused: false}}}} =
          state,
        _cp,
        _mods
      ) do
    {:passthrough, MingaEditor.Shell.Traditional.HoverPopupWorkflow.dismiss(state)}
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
        %{shell_runtime: %{state: %{hover_popup: nil}}} = state,
        _row,
        _col,
        _btn,
        _mods,
        _type,
        _cc
      ) do
    {:passthrough, state}
  end

  # Scroll wheel over the popup scrolls its content. The popup node only receives
  # wheel events when the pointer is inside its rect (scroll routing), so scrolling
  # works whether or not the popup is keyboard-focused (#2629, AC-3).
  def handle_mouse(
        %{shell_runtime: %{state: %{hover_popup: %HoverPopup{}}}} = state,
        _r,
        _c,
        :wheel_down,
        _m,
        _t,
        _cc
      ) do
    {:handled, MingaEditor.Shell.Traditional.HoverPopupWorkflow.scroll_down(state)}
  end

  def handle_mouse(
        %{shell_runtime: %{state: %{hover_popup: %HoverPopup{}}}} = state,
        _r,
        _c,
        :wheel_up,
        _m,
        _t,
        _cc
      ) do
    {:handled, MingaEditor.Shell.Traditional.HoverPopupWorkflow.scroll_up(state)}
  end

  # A click inside the popup focuses it for scrolling rather than dismissing it
  # (#2629, AC-4). This clause only runs when the pointer hit the popup rect, so a
  # click outside still falls through to the buffer (which dismisses on motion).
  def handle_mouse(
        %{shell_runtime: %{state: %{hover_popup: %HoverPopup{}}}} = state,
        _r,
        _c,
        :left,
        _m,
        :press,
        _cc
      ) do
    {:handled, MingaEditor.Shell.Traditional.HoverPopupWorkflow.focus(state)}
  end

  # Pointer motion inside the popup keeps it alive (#2629, AC-1). Swallowing the
  # event here stops it bubbling to the buffer handler that would dismiss it.
  def handle_mouse(
        %{shell_runtime: %{state: %{hover_popup: %HoverPopup{}}}} = state,
        _r,
        _c,
        _btn,
        _m,
        :motion,
        _cc
      ) do
    {:handled, state}
  end

  def handle_mouse(state, _row, _col, _btn, _mods, _type, _cc) do
    {:passthrough, state}
  end
end
