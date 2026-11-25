defmodule MingaEditor.Agent.TasksTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Event.ToolEnd
  alias MingaAgent.ToolApproval.Preview
  alias MingaAgent.ToolApproval.Public
  alias MingaAgent.ToolApproval.Target
  alias MingaAgent.TodoItem
  alias MingaEditor.Agent.Tasks
  alias MingaEditor.Agent.Tasks.Entry
  alias MingaEditor.Agent.Tasks.Subagent

  defp session, do: spawn(fn -> :ok end)

  defp approval(id) do
    Public.new(
      Target.new("session-#{id}", "request-#{id}", "call-#{id}"),
      "write_file",
      %{"path" => "test/usage_limit_test.exs"},
      Preview.new(:diff, "Create test/usage_limit_test.exs +86", ["+ defmodule"])
    )
  end

  defp entry(tasks, pid) do
    {:ok, entry} = Tasks.fetch(tasks, pid)
    entry
  end

  defp state(tasks, pid), do: tasks |> entry(pid) |> Entry.state()

  describe "a task's state" do
    setup do
      pid = session()
      {:ok, pid: pid, tasks: Tasks.follow(Tasks.new(), pid, 0, title: "Add tests")}
    end

    test "every state a task shows comes from its session's events", %{pid: pid, tasks: tasks} do
      cases = [
        {[], nil},
        {[{:status_changed, :thinking}], :working},
        {[{:status_changed, :thinking}, {:status_changed, :idle}], :done},
        {[{:status_changed, :thinking}, {:approval_pending, approval(1)}], :needs_you},
        {[{:status_changed, :thinking}, {:retry_scheduled, 40_000, "HTTP 429"}], :waiting},
        {[{:status_changed, :thinking}, {:model_limit_reached, "Pro limit reached"}], :waiting},
        {[{:status_changed, :thinking}, {:error, "test run crashed"}], :failed},
        {[{:question_requested, :q1, "Which file?"}], :needs_you},
        {[{:question_requested, :q1, "Which file?"}, {:question_answered, :q1}], nil},
        {[{:status_changed, :thinking}, {:status_changed, :stopped}], :stopped},
        # A restored conversation that never ran a turn is at rest, not stopped.
        {[{:status_changed, :stopped}], nil},
        {[{:status_changed, :idle}, {:status_changed, :stopped}], nil}
      ]

      for {events, expected} <- cases do
        observed = Enum.reduce(events, tasks, &Tasks.observe(&2, pid, &1, 10))

        assert state(observed, pid) == expected,
               "#{inspect(events)} should be #{inspect(expected)}"
      end
    end

    test "a session's turn can be stopped while it reports one, without counting as progress", %{
      pid: pid,
      tasks: tasks
    } do
      assert Tasks.stoppable(tasks) == []
      {:ok, before} = Tasks.fetch(tasks, pid)

      working = Tasks.observe(tasks, pid, {:stop_target_changed, {"record", "turn-1"}}, 9_999)
      assert Tasks.stoppable(working) == [{pid, {"record", "turn-1"}}]

      {:ok, entry} = Tasks.fetch(working, pid)
      assert entry.changed_at == before.changed_at

      ended = Tasks.observe(working, pid, {:stop_target_changed, nil}, 9_999)
      assert Tasks.stoppable(ended) == []
    end

    test "a restarted session has no turn to stop until it reports one", %{pid: pid, tasks: tasks} do
      working = Tasks.observe(tasks, pid, {:stop_target_changed, {"record", "turn-1"}}, 1)
      replacement = session()

      assert working |> Tasks.replace(pid, replacement, 2) |> Tasks.stoppable() == []
    end

    test "an open approval needs you before any other state", %{pid: pid, tasks: tasks} do
      tasks =
        tasks
        |> Tasks.observe(pid, {:error, "boom"}, 1)
        |> Tasks.observe(pid, {:approval_pending, approval(1)}, 2)

      assert state(tasks, pid) == :needs_you
    end

    test "the session resolving the approval clears it, and only the request it names", %{
      pid: pid,
      tasks: tasks
    } do
      pending = Tasks.observe(tasks, pid, {:approval_pending, approval(1)}, 1)

      assert pending
             |> Tasks.observe(pid, {:approval_resolved, approval(2).target, :approve}, 2)
             |> state(pid) ==
               :needs_you

      resolved =
        Tasks.observe(pending, pid, {:approval_resolved, approval(1).target, :approve}, 2)

      assert Tasks.approval(resolved, pid) == nil
    end

    test "a retried request that streams output is working again", %{pid: pid, tasks: tasks} do
      retrying =
        tasks
        |> Tasks.observe(pid, {:status_changed, :thinking}, 1)
        |> Tasks.observe(pid, {:retry_scheduled, 2_000, "HTTP 429"}, 2)
        |> Tasks.observe(pid, {:status_changed, :thinking}, 3)

      assert state(retrying, pid) == :waiting
      assert retrying |> Tasks.observe(pid, :output_streamed, 4) |> state(pid) == :working
    end

    test "a usage limit waits until the next turn starts", %{pid: pid, tasks: tasks} do
      limited =
        tasks
        |> Tasks.observe(pid, {:status_changed, :error}, 1)
        |> Tasks.observe(pid, {:model_limit_reached, "Pro limit reached"}, 1)

      assert limited |> Tasks.observe(pid, :output_streamed, 2) |> state(pid) == :waiting

      assert limited |> Tasks.observe(pid, {:status_changed, :thinking}, 3) |> state(pid) ==
               :working
    end

    test "working again clears a failure; a finished turn clears waiting", %{
      pid: pid,
      tasks: tasks
    } do
      failed = Tasks.observe(tasks, pid, {:error, "boom"}, 1)

      assert failed |> Tasks.observe(pid, {:status_changed, :thinking}, 2) |> state(pid) ==
               :working

      waiting =
        tasks
        |> Tasks.observe(pid, {:status_changed, :thinking}, 1)
        |> Tasks.observe(pid, {:retry_scheduled, 1_000, "HTTP 429"}, 2)

      assert waiting |> Tasks.observe(pid, {:status_changed, :idle}, 3) |> state(pid) == :done
    end
  end

  describe "a task's words" do
    setup do
      pid = session()
      {:ok, pid: pid, tasks: Tasks.follow(Tasks.new(), pid, 0)}
    end

    test "name what the task is doing in the state's own word", %{pid: pid, tasks: tasks} do
      todos = [
        %TodoItem{id: "1", description: "Read", status: :done},
        %TodoItem{id: "2", description: "Edit", status: :in_progress},
        %TodoItem{id: "3", description: "Test", status: :pending}
      ]

      working =
        tasks
        |> Tasks.observe(pid, {:status_changed, :tool_executing}, 1)
        |> Tasks.observe(pid, {:tool_started, "t1", "edit_file", %{}}, 1)
        |> Tasks.observe(pid, {:todo_plan_updated, todos}, 1)

      assert Entry.words(entry(working, pid), 1) == "Running edit_file · step 2 of 3"

      needs_you = Tasks.observe(tasks, pid, {:approval_pending, approval(1)}, 1)

      assert Entry.words(entry(needs_you, pid), 1) ==
               "Needs you · wants to change a file"

      waiting = Tasks.observe(tasks, pid, {:retry_scheduled, 40_000, "HTTP 429"}, 0)
      assert Entry.words(entry(waiting, pid), 0) == "Waiting · rate limited, retry in 40 s"
      assert Entry.words(entry(waiting, pid), 39_500) == "Waiting · rate limited, retry in 1 s"

      failed = Tasks.observe(tasks, pid, {:error, "test run crashed"}, 1)
      assert Entry.words(entry(failed, pid), 1) == "Failed · test run crashed"

      goal_only = Tasks.observe(tasks, pid, {:title_changed, "Add tests"}, 1)
      assert Entry.words(entry(goal_only, pid), 1) == "Starting"
    end

    test "a task is titled by its first goal and keeps it", %{pid: pid, tasks: tasks} do
      assert Entry.title(entry(tasks, pid)) == "New task"

      named =
        tasks
        |> Tasks.name(pid, "Add tests for the classifier\nwith a table")
        |> Tasks.name(pid, "Something later")

      assert Entry.title(entry(named, pid)) == "Add tests for the classifier"

      renamed = Tasks.observe(named, pid, {:title_changed, "Usage-limit tests"}, 1)
      assert Entry.title(entry(renamed, pid)) == "Usage-limit tests"
    end
  end

  describe "following sessions" do
    test "a session is followed from its subscription, and a late event cannot bring a stopped one back" do
      pid = session()

      assert Tasks.new() |> Tasks.observe(pid, {:status_changed, :thinking}, 1) |> Tasks.empty?()

      followed = Tasks.observe(Tasks.new(), pid, {:credentials_status, true}, 1)
      assert {:ok, _entry} = Tasks.fetch(followed, pid)

      forgotten = Tasks.forget(followed, pid)
      assert forgotten |> Tasks.observe(pid, {:status_changed, :idle}, 2) |> Tasks.empty?()
    end

    test "a session becomes a task row only once it has a goal" do
      cases = [
        {"an opened, never prompted conversation", [], false},
        {"a connection that comes and goes",
         [{:credentials_status, true}, {:connection_changed, :ready}], false},
        {"a provider failure before any prompt", [{:error, "provider exited"}], false},
        {"its first prompt names it", [{:title_changed, "Add tests"}], true},
        {"a prompt starts work", [{:status_changed, :thinking}], true},
        {"a finished turn", [{:status_changed, :thinking}, {:status_changed, :idle}], true},
        {"an untitled turn that fails", [{:status_changed, :thinking}, {:error, "HTTP 500"}],
         true},
        {"an untitled turn that is stopped",
         [{:status_changed, :thinking}, {:status_changed, :stopped}], true},
        {"an approval asks for you", [{:approval_pending, approval(1)}], true}
      ]

      for {label, events, shown?} <- cases do
        pid = session()

        tasks =
          Enum.reduce(events, Tasks.new() |> Tasks.follow(pid, 0), fn event, acc ->
            Tasks.observe(acc, pid, event, 1)
          end)

        assert Entry.goal?(entry(tasks, pid)) == shown?, label

        assert Enum.any?(Tasks.tree(tasks), &match?(%{item: %Entry{pid: ^pid}}, &1)) == shown?,
               label

        assert Tasks.empty?(tasks) == not shown?, label
      end
    end

    test "a task started from the drawer has its goal from the start" do
      pid = session()
      id = make_ref()
      {tasks, _seq} = Tasks.start(Tasks.new(), id, "Add tests", 0)
      tasks = Tasks.bind(tasks, id, pid, 1)

      assert [%{item: %Entry{pid: ^pid, title: "Add tests"}}] = Tasks.tree(tasks)
    end

    test "a disconnected node's tasks are forgotten" do
      pid = session()
      tasks = Tasks.follow(Tasks.new(), pid, 0)

      assert tasks |> Tasks.forget_node(:other@host) |> Tasks.fetch(pid) ==
               Tasks.fetch(tasks, pid)

      assert tasks |> Tasks.forget_node(node()) |> Tasks.empty?()
    end
  end

  describe "the task tree" do
    test "orders top-level tasks needs-you first, then working, waiting, stopped, failed and done" do
      seeds = [
        done: [{:status_changed, :thinking}, {:status_changed, :idle}],
        failed: [{:error, "crashed"}],
        stopped: [{:status_changed, :thinking}, {:status_changed, :stopped}],
        waiting: [{:retry_scheduled, 40_000, "HTTP 429"}],
        working: [{:status_changed, :thinking}],
        needs_you: [{:approval_pending, approval(1)}]
      ]

      tasks =
        Enum.reduce(seeds, Tasks.new(), fn {name, events}, acc ->
          pid = session()
          acc = Tasks.follow(acc, pid, 0, title: Atom.to_string(name))
          Enum.reduce(events, acc, &Tasks.observe(&2, pid, &1, 1))
        end)

      assert Enum.map(Tasks.tree(tasks), &{title(&1.item), Tasks.Entry.state(&1.item)}) == [
               {"needs_you", :needs_you},
               {"working", :working},
               {"waiting", :waiting},
               {"stopped", :stopped},
               {"failed", :failed},
               {"done", :done}
             ]
    end

    test "lists needs-you first, then by state, with subagents beneath their task" do
      [done, working, asks, child] = for _ <- 1..4, do: session()

      tasks =
        Tasks.new()
        |> Tasks.follow(done, 0, title: "Docs")
        |> Tasks.observe(done, {:status_changed, :thinking}, 1)
        |> Tasks.observe(done, {:status_changed, :idle}, 2)
        |> Tasks.follow(working, 0, title: "Plan limit")
        |> Tasks.observe(working, {:status_changed, :thinking}, 3)
        |> Tasks.observe(working, {:tool_started, "s1", "subagent", %{"task" => "Fact-check"}}, 4)
        |> Tasks.follow(asks, 0, title: "Tests")
        |> Tasks.observe(asks, {:approval_pending, approval(1)}, 1)
        |> Tasks.follow(child, 5, title: "Background audit", parent: working)

      assert Enum.map(Tasks.tree(tasks), fn %{item: item, depth: depth} ->
               {title(item), depth}
             end) == [
               {"Tests", 0},
               {"Plan limit", 0},
               {"Fact-check", 1},
               {"Background audit", 1},
               {"Docs", 0}
             ]

      assert Tasks.counts(tasks) == %{needs_you: 1, working: 2, done: 1}
      assert Tasks.needs_you_count(tasks) == 1
    end

    test "a foreground subagent settles with its tool call; a background call is its own task" do
      pid = session()

      tasks =
        Tasks.new()
        |> Tasks.follow(pid, 0)
        |> Tasks.observe(pid, {:tool_started, "s1", "subagent", %{"task" => "One"}}, 1)
        |> Tasks.observe(pid, {:tool_started, "s2", "subagent", %{"task" => "Two"}}, 1)
        |> Tasks.observe(
          pid,
          {:tool_started, "s3", "subagent", %{"task" => "Bg", "background" => true}},
          1
        )
        |> Tasks.observe(
          pid,
          {:tool_ended, %ToolEnd{tool_call_id: "s1", name: "subagent", outcome: :complete}},
          2
        )
        |> Tasks.observe(
          pid,
          {:tool_ended,
           %ToolEnd{tool_call_id: "s2", name: "subagent", outcome: :error, is_error: true}},
          2
        )

      assert [%Subagent{title: "One", state: :done}, %Subagent{title: "Two", state: :failed}] =
               entry(tasks, pid).subagents
    end

    test "a restarted session keeps its task; a stopped one is forgotten" do
      [old, new, child] = for _ <- 1..3, do: session()

      tasks =
        Tasks.new()
        |> Tasks.follow(old, 0, title: "Tests")
        |> Tasks.observe(old, {:approval_pending, approval(1)}, 1)
        |> Tasks.follow(child, 1, title: "Child", parent: old)
        |> Tasks.observe(old, {:status_changed, :thinking}, 1)
        |> Tasks.observe(old, {:retry_scheduled, 1_000, "HTTP 429"}, 1)
        |> Tasks.replace(old, new, 2)

      assert Entry.title(entry(tasks, new)) == "Tests"
      assert Tasks.approval(tasks, new) == nil
      assert entry(tasks, new) |> Entry.state() == nil
      assert entry(tasks, child).parent == new
      assert Tasks.fetch(Tasks.forget(tasks, new), new) == :error
    end
  end

  defp title(%Entry{} = entry), do: Entry.title(entry)
  defp title(%Subagent{title: title}), do: title
end
