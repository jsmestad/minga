defmodule Minga.Test.Storyboard.Scenarios.Files do
  @moduledoc "Registry entries for the `files` journey: the switcher, the file tree and file lists."

  import Minga.Test.Storyboard.Assertions

  alias Minga.Test.Storyboard.Check
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
      Entry.built("files.switcher.no_match",
        reach: "1 SPC , chrome_stat_test",
        recognize: &Model.empty_picker?(&1, ~r/switch buffer/i, ~r/^Nothing matches/),
        checks: [
          Check.new(
            "no match says what was searched and offers create and search rows",
            fn model ->
              assert_empty_state(model,
                title: "Nothing matches “chrome_stat_test”.",
                description: "Searched 1 open buffer.",
                actions: [
                  {"new file", "Create chrome_stat_test"},
                  {"SPC s p", "Search the project for chrome_stat_test"}
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
      Entry.built("files.tree.empty",
        start: [empty_dirs: ["notes"]],
        reach: "1 SPC o p j .",
        recognize: &(Model.open?(&1, :file_tree) and &1.ui.file_tree.status == :empty),
        checks: [
          Check.new(
            "an empty folder says so and offers a new file or folder in the tree's own keys",
            fn model ->
              assert_empty_state(model,
                title: "notes/ is empty.",
                description: "Make the first file or folder here.",
                actions: [{"a", "New file"}, {"A", "New folder"}]
              )
            end
          ),
          Check.new(
            "the tree keeps the keyboard, so j and k move the steps",
            &assert_focus(&1, :file_tree)
          )
        ]
      ),
      Entry.pending("files.file_list", 4054, "picker results exported to a buffer"),
      Entry.built("files.project_find",
        reach: "1 SPC SPC",
        # Mode pill, then the Find file in project row.
        click_reach: [
          {:gui_action, {:empty_state_activate, "recent-1"}},
          {:gui_action, {:execute_command, "which_key_open"}},
          {:gui_action, {:which_key_press, "SPC", ?\s, 0}}
        ],
        recognize: &(Model.open?(&1, :picker) and &1.picker_title =~ ~r/find file/i)
      )
    ]
  end
end
