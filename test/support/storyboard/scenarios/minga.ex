defmodule Minga.Test.Storyboard.Scenarios.Minga do
  @moduledoc "Registry entries for the `minga` journey: tasks, review, conversation, approvals and the act menu."

  import ExUnit.Assertions
  import Minga.Test.Storyboard.Assertions

  alias Minga.Test.Storyboard.Check
  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Model
  alias Minga.Test.Storyboard.Scenarios.Edit

  # The conversation the factory seeds: your message, Minga's answer, and three
  # finished tool steps, before the turn that is working. A stopped conversation
  # was stopped while a find ran: Stop leaves that step stopped, the way
  # `MingaAgent.Session.stop_turn/2` does mid-tool.
  # A notice longer than any transcript width: its last words say what to do, so
  # every frontend shows it whole, wrapped, never clipped.
  @long_notice "Saved the retry notes to lib/native/usage_limit/notes.md; open that file to review the plan, window and reset time."

  @spec conversation(:working | :stopped) :: keyword()
  defp conversation(turn) do
    [
      messages: conversation_messages(turn),
      notices: [{@long_notice, :info}],
      prompt: "Also show the reset time in the modeline.",
      turn: turn,
      queue: ["Then run the session tests and fix what fails."]
    ]
  end

  @spec conversation_messages(:working | :stopped) :: [MingaAgent.Message.t()]
  defp conversation_messages(:working), do: finished_steps()

  defp conversation_messages(:stopped),
    do:
      finished_steps() ++
        [{:tool_call, tool_call("t4", "find", %{"pattern" => "lib/other.ex"}, :cancelled)}]

  @spec finished_steps() :: [MingaAgent.Message.t()]
  defp finished_steps do
    [
      {:user, "Show the plan limit and when it resets instead of \"rate limited\"."},
      {:assistant,
       "A 429 with usage_limit_reached is its own case. I'll carry the plan, window and reset time on the error."},
      {:tool_call, tool_call("t1", "read_file", %{"path" => "lib/native.ex"}, :complete)},
      {:tool_call, tool_call("t2", "edit_file", %{"path" => "lib/retry.ex"}, :complete)},
      {:tool_call,
       tool_call("t3", "shell", %{"command" => "mix test test/retry_test.exs"}, :error)}
    ]
  end

  @spec tool_call(String.t(), String.t(), map(), MingaAgent.ToolCall.status()) ::
          MingaAgent.ToolCall.t()
  defp tool_call(id, name, args, status) do
    %MingaAgent.ToolCall{
      id: id,
      name: name,
      args: args,
      status: status,
      is_error: status != :complete,
      result: tool_result(status)
    }
  end

  @spec tool_result(MingaAgent.ToolCall.status()) :: String.t()
  defp tool_result(:complete), do: "ok"
  defp tool_result(:error), do: "1 failure"
  defp tool_result(:cancelled), do: "stopped"

  @spec conversation?(Model.t(), :working | :stopped) :: boolean()
  # Any open conversation that is not stopped is the conversation scenario: SPC a v
  # opens it idle, and a sent message makes it work.
  defp conversation?(%Model{conversation: %{status: status}} = model, turn) do
    Model.open?(model, :agent_chat) and status == :stopped == (turn == :stopped)
  end

  defp conversation?(%Model{}, _turn), do: false

  @spec conversation_checks(:working | :stopped, [{String.t(), String.t()}]) :: [Check.t()]
  defp conversation_checks(turn, hints) do
    [
      Check.new("the composer has the keyboard, in Insert", fn model ->
        model |> assert_focus(:agent) |> assert_mode(:insert)
      end),
      Check.new("messages carry their speaker: You, then Minga", fn model ->
        blocks = model.conversation.blocks
        assert Enum.take(Enum.filter(blocks, &(&1 in [:you, :minga])), 2) == [:you, :minga]
        model
      end),
      Check.new("each tool step is one sentence in a shared state", fn model ->
        steps = for {:step, state, text} <- model.conversation.blocks, do: {state, text}
        assert steps == expected_steps(turn)
        model
      end),
      Check.new("a long notice reaches the transcript whole", fn model ->
        assert {:notice, :info, @long_notice} in model.conversation.blocks
        model
      end),
      Check.new("the composer's hints name the keys that work here", fn model ->
        assert model.conversation.hints == hints
        model
      end),
      Check.new(
        "the modeline says Minga is #{turn}",
        &assert_state(&1, :modeline, if(turn == :stopped, do: :stopped, else: :working))
      )
    ] ++ stop_checks(turn)
  end

  @spec expected_steps(:working | :stopped) :: [{atom(), String.t()}]
  defp expected_steps(turn) do
    finished = [
      {:done, "Read lib/native.ex"},
      {:done, "Edited lib/retry.ex"},
      {:failed, "Could not run `mix test test/retry_test.exs`"}
    ]

    if turn == :stopped,
      do: finished ++ [{:stopped, "Stopped while finding lib/other.ex"}],
      else: finished
  end

  # A deliberate stop reads as a stop: the step it interrupted is stopped, the
  # only notice is "Stopped", and no reconciliation wording or failure appears.
  @spec stop_checks(:working | :stopped) :: [Check.t()]
  defp stop_checks(:working), do: []

  defp stop_checks(:stopped) do
    [
      Check.new("Stop leaves one plain notice and nothing red", fn model ->
        notices = for {:notice, level, text} <- model.conversation.blocks, do: {level, text}
        assert {:info, "Stopped"} in notices
        refute Enum.any?(notices, fn {level, _text} -> level == :error end)

        refute Enum.any?(notices, fn {_level, text} ->
                 text =~ ~r/reconcil|indeterminate|admitted|unadmitted/i
               end)

        model
      end)
    ]
  end

  @doc "Every `minga` entry."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      Entry.built("minga.whichkey",
        reach: "SPC a (pause)",
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
      Entry.built("minga.conversation",
        start: [conversation: conversation(:working)],
        reach: "SPC a v",
        recognize: &conversation?(&1, :working),
        checks:
          conversation_checks(:working, [
            {"esc ↩", "send"},
            {"⌥↩", "queue"},
            {"⌃C", "stop"},
            {"esc", "normal"}
          ])
      ),
      Entry.built("minga.conversation.stopped",
        start: [conversation: conversation(:stopped)],
        reach: "SPC a v",
        recognize: &conversation?(&1, :stopped),
        checks:
          conversation_checks(:stopped, [
            {"esc ↩", "continue"},
            {"⌥↩", "queue"},
            {"esc", "normal"}
          ])
      ),
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
