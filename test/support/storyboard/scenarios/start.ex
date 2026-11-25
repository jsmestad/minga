defmodule Minga.Test.Storyboard.Scenarios.Start do
  @moduledoc "Registry entries for the `start` journey: launch, opening a project, quitting."

  import Minga.Test.Storyboard.Assertions

  alias Minga.Test.Storyboard.Check
  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Model

  @doc "Every `start` entry."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      Entry.pending(
        "start.empty",
        4056,
        "the home buffer outside a project lands with `minga .`"
      ),
      Entry.pending("start.open_dir.home", 4056, "the project home buffer lands with `minga .`"),
      Entry.pending(
        "start.open_dir.restored",
        4056,
        "session restore with the echo note lands with `minga .`"
      ),
      Entry.pending(
        "start.open_dir.subdir",
        4057,
        "opening a subdirectory goes to the project root"
      ),
      Entry.pending(
        "start.open_dir.not_project",
        4057,
        "a directory without markers opens as its own root"
      ),
      Entry.built("start.project_switcher.empty",
        reach: "SPC p p",
        recognize: &Model.empty_picker?(&1, ~r/switch project/i, ~r/^No projects yet/),
        checks: [
          Check.new(
            "no known projects says how Minga learns them and offers the next steps",
            fn model ->
              assert_empty_state(model,
                title: "No projects yet.",
                description: "Minga remembers folders you open.",
                actions: [{"SPC p a", "Add a folder"}, {"SPC f f", "Open a file"}]
              )
            end
          )
        ]
      ),
      Entry.pending(
        "start.quit.confirm",
        4056,
        "the quit prompt lists what is at stake with s, d and esc"
      ),
      Entry.pending("start.quit.farewell", 4056, "the one-line farewell")
    ]
  end
end
