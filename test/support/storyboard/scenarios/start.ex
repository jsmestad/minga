defmodule Minga.Test.Storyboard.Scenarios.Start do
  @moduledoc "Registry entries for the `start` journey: launch, opening a project, quitting."

  alias Minga.Test.Storyboard.Entry

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
      Entry.pending("start.project_switcher.empty", 4058, "empty lists point somewhere"),
      Entry.pending(
        "start.quit.confirm",
        4056,
        "the quit prompt lists what is at stake with s, d and esc"
      ),
      Entry.pending("start.quit.farewell", 4056, "the one-line farewell")
    ]
  end
end
