defmodule Minga.Test.Storyboard.Scenarios.Git do
  @moduledoc "Registry entries for the `git` journey: status and blame."

  import Minga.Test.Storyboard.Assertions

  alias Minga.Test.Storyboard.Check
  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Model

  @doc "Every `git` entry."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      Entry.built("git.status.clean",
        start: [git_status: %{branch: "main", ahead: 2, entries: []}],
        reach: "",
        recognize:
          &(Model.open?(&1, :git_status) and match?(%{ui: %{git_status: %{empty: %{}}}}, &1)),
        checks: [
          Check.new(
            "a clean tree says so and offers the push that waits first, in the panel's own keys",
            fn model ->
              assert_empty_state(model,
                title: "Nothing to commit on main.",
                description: "2 commits to push.",
                actions: [
                  {"P", "Push to remote"},
                  {"l", "Pull from remote"},
                  {"f", "Fetch from remote"}
                ]
              )
            end
          ),
          Check.new(
            "the panel keeps the keyboard, so j and k move the steps",
            &assert_focus(&1, :git_status)
          )
        ]
      ),
      Entry.pending("git.blame", 4059, "blame as one column grouped by commit")
    ]
  end
end
