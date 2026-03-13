defmodule Minga.Popup.Active do
  @moduledoc """
  Tracks the state of an open popup window.

  When a popup rule fires and creates a managed split (or floating overlay),
  an `Active` struct is stored on the window to record the rule that created
  it and the layout state needed to restore the previous arrangement when
  the popup is closed.

  ## Lifecycle

  1. A buffer name matches a `Popup.Rule` in the registry.
  2. `Popup.Lifecycle.open_popup/3` snapshots the current window tree
     and active window id, creates the popup split/float, and attaches
     this struct to the new window's `popup_meta` field.
  3. When the user dismisses the popup (quit key, auto-close, or explicit
     close), `Popup.Lifecycle.close_popup/2` reads this struct to restore
     the previous layout.
  """

  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.Popup.Rule

  @type t :: %__MODULE__{
          rule: Rule.t(),
          window_id: Window.id(),
          previous_tree: WindowTree.t() | nil,
          previous_active: Window.id()
        }

  @enforce_keys [:rule, :window_id, :previous_active]
  defstruct [
    :rule,
    :window_id,
    :previous_tree,
    previous_active: 1
  ]

  @doc """
  Creates a new active popup record.

  Captures the rule that matched, the window id of the new popup window,
  and the layout state from before the popup was opened.
  """
  @spec new(Rule.t(), Window.id(), WindowTree.t() | nil, Window.id()) :: t()
  def new(%Rule{} = rule, window_id, previous_tree, previous_active)
      when is_integer(window_id) and is_integer(previous_active) do
    %__MODULE__{
      rule: rule,
      window_id: window_id,
      previous_tree: previous_tree,
      previous_active: previous_active
    }
  end
end
