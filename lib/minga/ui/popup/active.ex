defmodule Minga.UI.Popup.Active do
  @moduledoc """
  Tracks the state of an open popup window.

  When a popup rule fires and creates a managed split (or floating overlay),
  an `Active` struct is stored on the window to record the rule that created
  it and the previous active window id so focus can be restored when the
  popup is closed.

  ## Lifecycle

  1. A buffer name matches a `Popup.Rule` in the registry.
  2. `Popup.Lifecycle.open_popup/3` creates the popup split/float and
     attaches this struct to the new window's `popup_meta` field.
  3. When the user dismisses the popup (quit key, auto-close, or explicit
     close), `Popup.Lifecycle.close_popup/2` removes the popup's window
     from the current tree via `WindowTree.close/2` (like `delete-window`
     in Emacs) and restores focus using `previous_active`.

  This approach lets multiple popups coexist: closing one only removes its
  own window from the tree without affecting other popups.
  """

  alias Minga.Editor.Window
  alias Minga.UI.Popup.Rule

  @type t :: %__MODULE__{
          rule: Rule.t(),
          window_id: Window.id(),
          previous_active: Window.id()
        }

  @enforce_keys [:rule, :window_id, :previous_active]
  defstruct [
    :rule,
    :window_id,
    previous_active: 1
  ]

  @doc """
  Creates a new active popup record.

  Captures the rule that matched, the window id of the new popup window,
  and the previously active window id for focus restoration on close.
  """
  @spec new(Rule.t(), Window.id(), Window.id()) :: t()
  def new(%Rule{} = rule, window_id, previous_active)
      when is_integer(window_id) and is_integer(previous_active) do
    %__MODULE__{
      rule: rule,
      window_id: window_id,
      previous_active: previous_active
    }
  end
end
