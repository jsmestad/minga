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

  alias MingaEditor.Commands
  alias MingaEditor.HoverPopup
  alias MingaEditor.LspActions

  # Escape and Enter codepoints from the port protocol
  @key_escape 27
  @key_enter 13

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(%{shell_runtime: %{state: %{hover_popup: nil}}} = state, _codepoint, _modifiers) do
    {:passthrough, state}
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

  # When focused, j scrolls down
  def handle_key(
        %{shell_runtime: %{state: %{hover_popup: %MingaEditor.HoverPopup{focused: true}}}} = state,
        ?j,
        0
      ) do
    {:handled, MingaEditor.Shell.Traditional.HoverPopupWorkflow.scroll_down(state)}
  end

  # When focused, k scrolls up
  def handle_key(
        %{shell_runtime: %{state: %{hover_popup: %MingaEditor.HoverPopup{focused: true}}}} = state,
        ?k,
        0
      ) do
    {:handled, MingaEditor.Shell.Traditional.HoverPopupWorkflow.scroll_up(state)}
  end

  # When focused, Enter accepts the popup's Open action when one exists.
  def handle_key(
        %{
          shell_runtime: %{state: %{hover_popup: %HoverPopup{focused: true, open_action: action}}}
        } = state,
        @key_enter,
        _mods
      )
      when action != nil do
    state = MingaEditor.Shell.Traditional.HoverPopupWorkflow.dismiss(state)
    {:handled, execute_open_action(state, action)}
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

  @spec execute_open_action(state(), HoverPopup.open_action()) :: state()
  defp execute_open_action(state, {:goto_location, uri, line, col}) do
    LspActions.open_location(state, uri, line, col)
  end

  defp execute_open_action(state, {:open_session, session_id, tool_call_id}) do
    Commands.Agent.open_session(state, session_id, tool_call_id)
  end

  defp execute_open_action(state, action) when is_atom(action) do
    case Commands.execute(state, action) do
      {new_state, _action} -> new_state
      new_state -> new_state
    end
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
