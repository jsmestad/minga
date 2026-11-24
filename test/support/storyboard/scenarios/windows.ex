defmodule Minga.Test.Storyboard.Scenarios.Windows do
  @moduledoc """
  Registry entries for the `windows` journey: drawers and focus.

  `windows.narrow` is `state_of = true` in the inventory: a state every place can be in, proved by the places themselves, so it has no entry here.
  """

  alias Minga.Test.Storyboard.Entry

  @doc "Every `windows` entry."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      Entry.pending(
        "windows.drawer_stack",
        4045,
        "one drawer at a time, closing returns to the replaced one"
      ),
      Entry.pending("windows.focus_lost", 4062, "focus reporting dims borders and the cursor")
    ]
  end
end
