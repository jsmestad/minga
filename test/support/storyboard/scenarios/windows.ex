defmodule Minga.Test.Storyboard.Scenarios.Windows do
  @moduledoc "Registry entries for the `windows` journey: narrow windows, drawers and focus."

  alias Minga.Test.Storyboard.Entry

  @doc "Every `windows` entry."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      Entry.pending("windows.narrow", 4043, "the modeline truncates by priority"),
      Entry.pending(
        "windows.drawer_stack",
        4045,
        "one drawer at a time, closing returns to the replaced one"
      ),
      Entry.pending("windows.focus_lost", 4062, "focus reporting dims borders and the cursor")
    ]
  end
end
