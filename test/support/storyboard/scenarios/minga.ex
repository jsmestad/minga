defmodule Minga.Test.Storyboard.Scenarios.Minga do
  @moduledoc "Registry entries for the `minga` journey: tasks, review, conversation, approvals and the act menu."

  import Minga.Test.Storyboard.Assertions

  alias Minga.Test.Storyboard.Check
  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Scenarios.Edit

  @doc "Every `minga` entry."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      Entry.built("minga.whichkey",
        reach: "SPC a (pause)",
        # Minga is working in the session, so the modeline carries its state while which-key is open.
        start: [minga: :thinking],
        recognize: &Edit.which_key?(&1, "SPC a"),
        explore: :which_key,
        checks: [
          Check.new("which-key is open on SPC a", &assert_which_key(&1, "SPC a")),
          Check.new(
            "the editor keeps the keyboard while which-key is open",
            &assert_focus(&1, :editor)
          ),
          Check.new("tasks is shown", &assert_keys_shown(&1, ["a"])),
          Check.pending(
            "conversation, review, inspect and watch fit on one panel",
            4028,
            &assert_keys_shown(&1, ["v", "r", "i", "w"])
          ),
          Check.new("Queue ›, Context › and Session › are groups", fn model ->
            model
            |> assert_group("q", "Queue")
            |> assert_group("x", "Context")
            |> assert_group("S", "Session")
          end),
          Check.pending(
            "Tasks shows a live needs-you count",
            4044,
            &assert_count(&1, "a", "1 needs you")
          ),
          Check.new(
            "the modeline says Minga is working, in the minga role",
            &assert_state(&1, :modeline, :working)
          )
        ]
      ),
      Entry.pending("minga.tasks.needs_you", 4045, "the tasks drawer"),
      Entry.pending("minga.tasks.list", 4045, "the tasks drawer"),
      Entry.pending("minga.tasks.working", 4045, "the tasks drawer"),
      Entry.pending("minga.tasks.empty", 4045, "the tasks drawer's empty state"),
      Entry.pending("minga.task.new", 4045, "the New task › prompt"),
      Entry.pending("minga.approval.diff", 4045, "the approval diff"),
      Entry.pending("minga.task.output", 4045, "a task's output"),
      Entry.pending(
        "minga.notification",
        4045,
        "the background notification when Minga needs you"
      ),
      Entry.pending("minga.review.buffer", 4051, "the *minga-review* buffer"),
      Entry.pending("minga.review.keep_all.confirm", 4051, "keep all changes, y/n"),
      Entry.pending("minga.review.all_decided", 4051, "review after the last change is decided"),
      Entry.pending("minga.review.empty", 4051, "nothing to review"),
      Entry.pending("minga.review.diff_inline", 4051, "the inline diff of Minga's change"),
      Entry.pending(
        "minga.review.in_file",
        4050,
        "Minga's changes in the gutter, reviewed in place"
      ),
      Entry.pending("minga.reject_all.confirm", 4049, "reject all changes, y/n"),
      Entry.pending("minga.conversation", 4055, "the conversation split and composer"),
      Entry.pending("minga.conversation.stopped", 4055, "the conversation after Stop"),
      Entry.pending("minga.queue", 4055, "the *minga-queue* buffer"),
      Entry.pending("minga.queue.empty", 4055, "an empty queue"),
      Entry.pending("minga.subagent.peek", 4046, "a subagent beside its parent"),
      Entry.pending("minga.hover.attribution", 4053, "hover on a line Minga wrote"),
      Entry.pending("minga.act_menu", 4052, "the act menu on a Minga change"),
      Entry.pending("minga.act_menu.filtered", 4052, "the act menu after typing"),
      Entry.pending("minga.act_menu.selection", 4052, "the act menu on a selection")
    ]
  end
end
