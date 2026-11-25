defmodule Minga.Test.Storyboard.Scenarios.Code do
  @moduledoc "Registry entries for the `code` journey: diagnostics, hover, code actions and references."

  import Minga.Test.Storyboard.Assertions

  alias Minga.Test.Storyboard.Check
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
      Entry.built("code.actions.none",
        reach: "SPC c a",
        recognize: &(is_binary(&1.echo) and &1.echo =~ ~r/^No code actions/),
        checks: [
          Check.new(
            "the echo line answers and names the next step, and nothing opens",
            fn model ->
              model
              |> assert_notice("No code actions at 1:1 (no language server)", [
                {"SPC a ?", "ask Minga"}
              ])
              |> assert_resting()
            end
          )
        ]
      ),
      Entry.built("code.references.none",
        reach: "SPC c D",
        recognize: &(is_binary(&1.echo) and &1.echo =~ ~r/^No references/),
        checks: [
          Check.new(
            "the echo line answers and names the next step, and nothing opens",
            fn model ->
              model
              |> assert_notice("No references to defmodule (no server)", [
                {"SPC s p", "search the project"}
              ])
              |> assert_resting()
            end
          )
        ]
      ),
      Entry.pending("code.hover.focused", 4053, "K again focuses the hover")
    ]
  end
end
