defmodule Minga.Test.Storyboard.Scenarios.Code do
  @moduledoc "Registry entries for the `code` journey: diagnostics, hover, code actions and references."

  import Minga.Test.Storyboard.Assertions

  alias Minga.Test.Storyboard.Check
  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Model

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
      Entry.built("code.diagnostics.none",
        reach: "SPC c x",
        recognize: &Model.empty_picker?(&1, ~r/diagnostics/i, ~r/^No problem/),
        checks: [
          Check.new("an empty list says so and points somewhere", fn model ->
            assert_empty_state(model,
              title: "No problems in this file.",
              description: "No language server checks this file.",
              actions: [
                {"SPC c l I", "Install a language server"},
                {"SPC c l i", "Show what ran"}
              ]
            )
          end)
        ]
      ),
      Entry.built("code.actions.none",
        reach: "1 SPC c a",
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
        reach: "1 SPC c D",
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
