defmodule Minga.Test.Storyboard.Scenarios.Search do
  @moduledoc "Registry entries for the `search` journey: buffer search, project search, quickfix."

  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Model

  @doc "Every `search` entry."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      Entry.pending("search.buffer.no_results", 4058, "no results name the next step"),
      Entry.pending("search.project.no_results", 4058, "no results become next steps"),
      Entry.pending("search.quickfix", 4059, "the quickfix drawer"),
      Entry.built("search.buffer",
        reach: "/",
        recognize: &(&1.mode == :search and not Model.open?(&1, :which_key))
      )
    ]
  end
end
