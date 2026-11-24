defmodule Minga.Test.Storyboard.Scenarios.Git do
  @moduledoc "Registry entries for the `git` journey: status and blame."

  alias Minga.Test.Storyboard.Entry

  @doc "Every `git` entry."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      Entry.pending("git.status.clean", 4058, "a clean tree says so and points somewhere"),
      Entry.pending("git.blame", 4059, "blame as one column grouped by commit")
    ]
  end
end
