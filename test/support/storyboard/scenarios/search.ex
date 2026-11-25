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
      Entry.built("search.project.no_results",
        reach: "SPC s p limit_lable ↩",
        recognize: &Model.empty_picker?(&1, ~r/search project/i, ~r/^No results/),
        checks: [
          Check.new(
            "no results say what was skipped and offer wider searches as rows",
            fn model ->
              assert_empty_state(model,
                title: "No results for “limit_lable”.",
                description: "Ignored and hidden files were skipped.",
                actions: [
                  {"-- -u", "Search ignored files too"},
                  {"--hidden", "Search hidden files too"},
                  {"-- -uu", "Search all files"}
                ]
              )
            end
          ),
          Check.new(
            "the prompt keeps the keyboard, so typing edits the query",
            &assert_focus(&1, :picker)
          )
        ]
      ),
      Entry.pending("search.quickfix", 4059, "the quickfix drawer"),
      Entry.built("search.buffer",
        reach: "/",
        recognize: &(&1.mode == :search and not Model.open?(&1, :which_key))
      )
    ]
  end
end
