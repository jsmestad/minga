defmodule Minga.Test.Storyboard.Scenarios.Code do
  @moduledoc "Registry entries for the `code` journey: diagnostics, hover, code actions and references."

  alias Minga.Test.Storyboard.Entry

  @doc "Every `code` entry."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      Entry.pending(
        "code.diagnostics.in_file",
        4059,
        "diagnostics share one gutter and one grammar"
      ),
      Entry.pending("code.hover", 4053, "the compact hover peek"),
      Entry.pending(
        "code.diagnostics.hover",
        4053,
        "hover on a diagnostic with Fix and Ask Minga"
      ),
      Entry.pending("code.diagnostics.none", 4058, "an empty diagnostics list points somewhere"),
      Entry.pending(
        "code.actions.none",
        4058,
        "no code actions name the next step in the echo area"
      ),
      Entry.pending(
        "code.references.none",
        4058,
        "no references name the next step in the echo area"
      ),
      Entry.pending("code.hover.focused", 4053, "K again focuses the hover")
    ]
  end
end
