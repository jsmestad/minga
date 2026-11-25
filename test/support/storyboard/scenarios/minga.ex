defmodule Minga.Test.Storyboard.Scenarios.Minga do
  @moduledoc "Registry entries for the `minga` journey: tasks, review, conversation, approvals and the act menu."

  import ExUnit.Assertions
  import Minga.Test.Storyboard.Assertions

  alias Minga.Test.Storyboard.Check
  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Model
  alias Minga.Test.Storyboard.Scenarios.Edit

  # Oldest first: a done task, a failed run, a rate-limited one, and one fanned out into subagents.
  # Oldest first: a done task, a failed test run and a rate-limited one.
  @settled_tasks [
    {"Update the agent docs for the Spine", :done},
    {"Run the session test suite", :failed},
    {"Refactor the picker sources", :waiting},
    {"Rename the queue buffer", :stopped}
  ]

  # The settled tasks, one fanned out into subagents, and one asking to create a file.
  @asking_tasks @settled_tasks ++
                  [
                    {"Show the plan limit instead of \"rate limited\"",
                     {:working,
                      subagents: ["Fact-check the reset times", "Read the usage-limit fixtures"]}},
                    {"Add tests for the usage-limit classifier", :needs_you}
                  ]

  @doc "Every `minga` entry."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      Entry.built("minga.whichkey",
        reach: "SPC a (pause)",
        # Mode pill, then the Minga row.
        click_reach: [
          {:gui_action, {:execute_command, "which_key_open"}},
          {:gui_action, {:which_key_press, "SPC", ?a, 0}}
        ],
        # Minga waits on you in the session, so the modeline carries Minga's state and the Tasks row its live
        # needs-you count while which-key is open.
        start: [minga: :needs_you],
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
          Check.new(
            "Tasks shows a live needs-you count",
            &assert_count(&1, "a", "1 needs you", :needs_you)
          ),
          Check.new(
            "entries read in the designed sections",
            &assert_sections(&1, ["Tasks", "Conversation", "Changes", "More"])
          ),
          Check.new(
            "the modeline says Minga needs you, in the needs-you role",
            &assert_state(&1, :modeline, :needs_you)
          )
        ]
      ),
      Entry.built("minga.tasks.needs_you",
        start: [tasks: @asking_tasks],
        reach: "1 SPC a a",
        recognize: &tasks_selected?(&1, :needs_you),
        checks: [
          Check.new(
            "the drawer has the keyboard and lists needs-you first",
            &assert_tasks_drawer/1
          ),
          Check.new(
            "the needs-you row shows its request and y a t n",
            &assert_tasks_selected(&1, :needs_you)
          ),
          Check.new("subagents sit beneath their task as a tree", &assert_tasks_tree/1),
          Check.new("the header counts each state", &assert_tasks_counts/1),
          Check.new("the modeline says Needs you", &assert_state(&1, :modeline, :needs_you))
        ]
      ),
      Entry.built("minga.tasks.list",
        start: [tasks: @settled_tasks],
        reach: "1 SPC a a",
        recognize: &tasks_list?/1,
        checks: [
          Check.new(
            "the drawer has the keyboard and every row its state",
            &assert_tasks_drawer/1
          ),
          Check.new("the header counts each state", &assert_tasks_counts/1)
        ]
      ),
      Entry.built("minga.tasks.working",
        start: [tasks: [{"Add tests for the usage-limit classifier", :needs_you}]],
        reach: "1 SPC a a y",
        recognize: &tasks_selected?(&1, :working),
        checks: [
          Check.new("the drawer keeps the keyboard", &assert_tasks_drawer/1),
          Check.new("the answered task is working again", &assert_tasks_selected(&1, :working))
        ]
      ),
      Entry.built("minga.tasks.empty",
        # An opened conversation that was never prompted is not a task, so the drawer is still empty.
        start: [tasks: [{"An opened conversation", :opened}]],
        reach: "1 SPC a a",
        recognize: &tasks_empty?/1,
        checks: [
          Check.new("the drawer has the keyboard", &assert_tasks_drawer/1),
          Check.new(
            "it says no one's at the table yet and offers New task first",
            &assert_empty_state(&1,
              title: "No one's at the table yet.",
              actions: [{"c", "New task"}, {"SPC a S h", "Resume an earlier session"}]
            )
          )
        ]
      ),
      Entry.built("minga.task.new",
        start: [tasks: @settled_tasks],
        reach: "1 SPC a a c f i x",
        recognize: &new_task_prompt?/1,
        checks: [
          Check.new("the prompt says New task ›", &assert(&1.minibuffer_prompt =~ "New task ›"))
        ]
      ),
      Entry.built("minga.approval.diff",
        start: [tasks: [{"Add tests for the usage-limit classifier", :needs_you}]],
        reach: "1 SPC a a =",
        recognize: &tasks_view?(&1, :diff),
        checks: [
          Check.new("the diff names the request and shows its lines", fn model ->
            drawer = model.ui.tasks_drawer
            assert drawer.view_title =~ "Create test/minga_agent/usage_limit_test.exs"
            assert drawer.view_lines != []
            model
          end),
          Check.new("the answers stay on the keys", &assert_keys_hinted(&1, ["y", "a", "t", "n"]))
        ]
      ),
      Entry.built("minga.task.output",
        start: [tasks: @settled_tasks],
        reach: "1 SPC a a j j o",
        recognize: &tasks_view?(&1, :output),
        checks: [
          Check.new("the output shows the run and its failure", fn model ->
            assert "Test run crashed" in model.ui.tasks_drawer.view_lines
            model
          end),
          Check.new("retry is on r", &assert_keys_hinted(&1, ["r"]))
        ]
      ),
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

  @doc "True when the tasks drawer's list is open with a selected row in `state`."
  @spec tasks_selected?(Model.t(), atom()) :: boolean()
  def tasks_selected?(
        %Model{ui: %{tasks_drawer: %{visible?: true, view: :list} = drawer}} = model,
        state
      ) do
    not new_task_prompt?(model) and selected_state?(drawer, state)
  end

  def tasks_selected?(%Model{}, _state), do: false

  @spec selected_state?(Minga.RenderModel.UI.TasksDrawer.t(), atom()) :: boolean()
  defp selected_state?(drawer, state) do
    case Minga.RenderModel.UI.TasksDrawer.selected(drawer) do
      %{state: ^state} -> true
      _other -> false
    end
  end

  @doc "True when the tasks drawer lists several tasks, none needs you, and the selected one is not working."
  @spec tasks_list?(Model.t()) :: boolean()
  def tasks_list?(
        %Model{
          ui: %{tasks_drawer: %{visible?: true, view: :list, rows: [_, _ | _] = rows} = drawer}
        } =
          model
      ) do
    not new_task_prompt?(model) and not Enum.any?(rows, &(&1.state == :needs_you)) and
      not selected_state?(drawer, :working)
  end

  def tasks_list?(%Model{}), do: false

  @doc "True when the tasks drawer is open with no tasks, showing its empty state."
  @spec tasks_empty?(Model.t()) :: boolean()
  def tasks_empty?(
        %Model{ui: %{tasks_drawer: %{visible?: true, view: :list, rows: [], empty: %{}}}} = model
      ),
      do: not new_task_prompt?(model)

  def tasks_empty?(%Model{}), do: false

  @doc "True when the tasks drawer shows one task's `:diff` or `:output`."
  @spec tasks_view?(Model.t(), :diff | :output) :: boolean()
  def tasks_view?(%Model{ui: %{tasks_drawer: %{visible?: true, view: view}}} = model, view),
    do: not new_task_prompt?(model)

  def tasks_view?(%Model{}, _view), do: false

  @doc "True when the New task › prompt is open."
  @spec new_task_prompt?(Model.t()) :: boolean()
  def new_task_prompt?(%Model{minibuffer_prompt: prompt}) when is_binary(prompt),
    do: String.contains?(prompt, "New task")

  def new_task_prompt?(%Model{}), do: false
end
