defmodule MingaEditor.Input.OverlaySink do
  @moduledoc """
  Swallow-by-default mouse handler for placed secondary overlays (#2281).

  The seven footer-band overlays (float popup, agent context, extension panel,
  observatory, edit timeline, notifications, extension overlay) are now FocusTree
  nodes with a real rect. A FocusTree node with no handler
  bubbles its mouse events to ancestors (router passthrough semantics), which
  would let a click or scroll over a visible overlay reach the buffer underneath
  and move its cursor. That is the exact bug the epic's AC-2 forbids.

  This handler is the minimal safety floor: it consumes (`:handled`) presses,
  releases, drags, and scroll wheel events that land inside the overlay's rect,
  so they never bubble to the buffer. It does not yet interpret them, per-surface
  activation semantics (clicking a notification, an observatory row, a timeline
  entry) land as the epic's follow-up children (#2330). Those children replace
  this sink with a surface-specific handler; until then, the overlay is safe to
  click without editing the buffer behind it.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

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
  def handle_mouse(state, _row, _col, _button, _mods, _event_type, _click_count) do
    # The router only calls this handler when the event already hit the overlay's
    # rect, so every event reaching here is over a visible overlay: swallow it so
    # it cannot bubble to the buffer. One handled verdict covers press, release,
    # drag, and wheel scroll.
    {:handled, state}
  end
end
