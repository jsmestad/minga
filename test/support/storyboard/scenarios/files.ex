defmodule Minga.Test.Storyboard.Scenarios.Files do
  @moduledoc "Registry entries for the `files` journey: the switcher, the file tree and file lists."

  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Model

  @doc "Every `files` entry."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      Entry.pending(
        "files.switcher",
        4056,
        "the SPC , switcher drawer with pinned, changed and recent"
      ),
      Entry.pending("files.switcher.no_match", 4058, "no match offers create and search rows"),
      Entry.pending("files.tree.empty", 4058, "the empty-folder anatomy in the file tree"),
      Entry.pending("files.file_list", 4054, "picker results exported to a buffer"),
      Entry.built("files.project_find",
        reach: "SPC SPC",
        recognize: &(Model.open?(&1, :picker) and &1.picker_title =~ ~r/find file/i)
      )
    ]
  end
end
