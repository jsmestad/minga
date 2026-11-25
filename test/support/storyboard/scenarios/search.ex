defmodule Minga.Test.Storyboard.Scenarios.Search do
  @moduledoc "Registry entries for the `search` journey: buffer search, project search, quickfix."

  import Minga.Test.Storyboard.Assertions

  alias Minga.Test.Storyboard.Check
  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Model

  @doc "Every `search` entry."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      Entry.built("search.buffer.no_results",
        reach: "/limit_lable ↩",
        recognize: &(is_binary(&1.echo) and &1.echo =~ ~r/^No matches for/),
        checks: [
          Check.new("the echo line says nothing matched and names the wider search", fn model ->
            assert_notice(model, "No matches for “limit_lable” in this buffer", [
              {"SPC s p", "search the project"}
            ])
          end)
        ]
      ),
      Entry.pending("search.project.no_results", 4058, "no results become next steps"),
      Entry.pending("search.quickfix", 4059, "the quickfix drawer"),
      Entry.built("search.buffer",
        reach: "/",
        recognize: &(&1.mode == :search and not Model.open?(&1, :which_key))
      )
    ]
  end
end
