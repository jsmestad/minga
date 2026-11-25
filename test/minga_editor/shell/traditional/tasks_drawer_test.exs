defmodule MingaEditor.Shell.Traditional.TasksDrawerTest do
  @moduledoc """
  The tasks drawer through the real Editor: `SPC a a` opens it, keys move and answer the selected task, `q` and `esc` close it, and one drawer shows at a time.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.RenderModel.UI.EmptyList
  alias Minga.RenderModel.UI.TasksDrawer
  alias Minga.Test.FakeTaskSession
  alias Minga.Test.Storyboard.Session, as: StoryboardSession

  defp drawer(ctx) do
    StoryboardSession.model(session(ctx)).ui.tasks_drawer
  end

  defp titles(%TasksDrawer{rows: rows}), do: Enum.map(rows, & &1.title)
  defp selected_title(model), do: TasksDrawer.selected(model).title

  setup do
    ctx = start_editor("hello world")
    {:ok, ctx: ctx}
  end

  test "SPC a a opens the drawer with the keyboard, needs-you first, and closes it again", %{
    ctx: ctx
  } do
    FakeTaskSession.start(ctx.editor, "Update the docs", :done)
    FakeTaskSession.start(ctx.editor, "Add tests for the classifier", :needs_you)
    FakeTaskSession.start(ctx.editor, "Show the plan limit", :working)

    refute drawer(ctx).visible?
    send_keys_sync(ctx, "<Space>aa")

    model = drawer(ctx)
    assert model.visible? and model.focused?

    assert titles(model) == [
             "Add tests for the classifier",
             "Show the plan limit",
             "Update the docs"
           ]

    assert %{state: :needs_you, detail: ["Create test/minga_agent/usage_limit_test.exs +86"]} =
             TasksDrawer.selected(model)

    assert model.counts == [needs_you: 1, working: 1, done: 1]

    send_keys_sync(ctx, "<Space>aa")
    refute drawer(ctx).visible?
  end

  test "y answers the selected task's approval through its session; keys never reach the file", %{
    ctx: ctx
  } do
    FakeTaskSession.start(ctx.editor, "Show the plan limit", :working)
    asking = FakeTaskSession.start(ctx.editor, "Add tests", :needs_you, observer: self())

    send_keys_sync(ctx, "<Space>aa")
    send_keys_sync(ctx, "j")
    assert selected_title(drawer(ctx)) == "Show the plan limit"
    send_keys_sync(ctx, "k")
    send_keys_sync(ctx, "x")
    send_keys_sync(ctx, "y")

    assert_receive {:fake_task_answered, ^asking, :approve}
    assert buffer_content(ctx) == "hello world"
    refute Enum.any?(drawer(ctx).rows, &(&1.state == :needs_you))
  end

  for {key, decision} <- [{"a", :approve_session}, {"t", :approve_turn}, {"n", :reject}] do
    test "#{key} answers with #{decision}", %{ctx: ctx} do
      asking = FakeTaskSession.start(ctx.editor, "Add tests", :needs_you, observer: self())
      send_keys_sync(ctx, "<Space>aa")
      send_keys_sync(ctx, unquote(key))
      assert_receive {:fake_task_answered, ^asking, unquote(decision)}
    end
  end

  test "an answer key held with Control or Alt answers nothing", %{ctx: ctx} do
    FakeTaskSession.start(ctx.editor, "Add tests", :needs_you, observer: self())
    send_keys_sync(ctx, "<Space>aa")
    send_keys_sync(ctx, "<C-y>")
    # Alt (0x04) held with n, as the frontends send it.
    send(ctx.editor, {:minga_input, {:key_press, ?n, 0x04}})
    _ = drawer(ctx)

    refute_received {:fake_task_answered, _pid, _decision}
    assert TasksDrawer.selected(drawer(ctx)).state == :needs_you
  end

  test "esc closes the drawer and leaves the request pending", %{ctx: ctx} do
    FakeTaskSession.start(ctx.editor, "Add tests", :needs_you, observer: self())
    send_keys_sync(ctx, "<Space>aa")
    send_keys_sync(ctx, "<Esc>")

    refute drawer(ctx).visible?
    refute_received {:fake_task_answered, _pid, _decision}

    send_keys_sync(ctx, "<Space>aa")
    assert TasksDrawer.selected(drawer(ctx)).state == :needs_you
  end

  test "a click on a row's action answers that row's task, wherever the selection is", %{ctx: ctx} do
    asking = FakeTaskSession.start(ctx.editor, "Add tests", :needs_you, observer: self())
    FakeTaskSession.start(ctx.editor, "Docs", :done)
    send_keys_sync(ctx, "<Space>aa")
    send_keys_sync(ctx, "j")

    row = Enum.find(drawer(ctx).rows, &(&1.state == :needs_you))
    send_gui_action(ctx, {:tasks_drawer_action, row.id, "y"})

    assert_receive {:fake_task_answered, ^asking, :approve}
  end

  test "one drawer at a time: Messages hides beneath the tasks drawer and q brings it back", %{
    ctx: ctx
  } do
    send_keys_sync(ctx, "<Space>tp")
    assert messages_visible?(ctx)

    send_keys_sync(ctx, "<Space>aa")
    assert drawer(ctx).visible?
    assert drawer(ctx).note == "Messages hidden · q returns"
    refute messages_visible?(ctx)

    send_keys_sync(ctx, "q")
    refute drawer(ctx).visible?
    assert messages_visible?(ctx)
  end

  test "an empty drawer says no one's at the table yet, offers New task first, and closes", %{
    ctx: ctx
  } do
    send_keys_sync(ctx, "<Space>aa")

    assert %TasksDrawer{
             visible?: true,
             rows: [],
             empty: %EmptyList{
               title: "No one's at the table yet.",
               selected: 0,
               actions: [
                 %EmptyList.Action{id: "agent_new_task", key: "c", label: "New task"},
                 %EmptyList.Action{id: "agent_session_history", key: "SPC a S h"}
               ]
             }
           } = drawer(ctx)

    send_keys_sync(ctx, "q")
    refute drawer(ctx).visible?
  end

  test "a drawer with tasks has no empty state", %{ctx: ctx} do
    FakeTaskSession.start(ctx.editor, "Docs", :done)
    send_keys_sync(ctx, "<Space>aa")
    assert %TasksDrawer{empty: nil, rows: [_row]} = drawer(ctx)
  end

  test "in the empty drawer j and k move between next steps and enter runs the selected one", %{
    ctx: ctx
  } do
    send_keys_sync(ctx, "<Space>aa")
    send_keys_sync(ctx, "j")
    assert drawer(ctx).empty.selected == 1
    send_keys_sync(ctx, "j")
    assert drawer(ctx).empty.selected == 1
    send_keys_sync(ctx, "k")
    assert drawer(ctx).empty.selected == 0

    send_keys_sync(ctx, "<CR>")
    assert StoryboardSession.model(session(ctx)).minibuffer_prompt =~ "New task ›"
  end

  test "an open conversation that was never prompted is not a task, so the drawer stays empty", %{
    ctx: ctx
  } do
    FakeTaskSession.start(ctx.editor, "unused", :opened)
    send_keys_sync(ctx, "<Space>aa")
    assert %TasksDrawer{visible?: true, rows: [], counts: [], empty: %EmptyList{}} = drawer(ctx)
  end

  defp messages_visible?(ctx),
    do: editor_state(ctx).shell_runtime.state.bottom_panel.visible

  describe "row actions" do
    test "= shows the request's diff, which still answers it; esc steps back to the list", %{
      ctx: ctx
    } do
      asking = FakeTaskSession.start(ctx.editor, "Add tests", :needs_you, observer: self())
      send_keys_sync(ctx, "<Space>aa")
      send_keys_sync(ctx, "=")

      model = drawer(ctx)
      assert model.view == :diff
      assert model.view_title =~ "Create test/minga_agent/usage_limit_test.exs +86"
      assert model.view_lines == ["+ defmodule MingaAgent.UsageLimitTest do"]

      send_keys_sync(ctx, "<Esc>")
      assert drawer(ctx).view == :list and drawer(ctx).visible?

      send_keys_sync(ctx, "=")
      send_keys_sync(ctx, "t")
      assert_receive {:fake_task_answered, ^asking, :approve_turn}
      assert drawer(ctx).view == :list
    end

    test "o shows a failed task's output and r retries it from there", %{ctx: ctx} do
      failed =
        FakeTaskSession.start(ctx.editor, "Run the session tests", :failed, observer: self())

      send_keys_sync(ctx, "<Space>aa")
      send_keys_sync(ctx, "o")

      model = drawer(ctx)
      assert model.view == :output
      assert "$ shell" in model.view_lines
      assert "Test run crashed" in model.view_lines

      send_keys_sync(ctx, "r")
      assert_receive {:fake_task_continued, ^failed}
      assert drawer(ctx).view == :list
    end

    test "x asks before stopping; n keeps the task running and y stops that exact turn", %{
      ctx: ctx
    } do
      working = FakeTaskSession.start(ctx.editor, "Plan limit", :working, observer: self())
      send_keys_sync(ctx, "<Space>aa")
      send_keys_sync(ctx, "x")
      assert drawer(ctx).prompt =~ "Stop “Plan limit”?"

      send_keys_sync(ctx, "n")
      assert drawer(ctx).prompt == ""
      refute_received {:fake_task_stopped, _pid, _target}

      send_keys_sync(ctx, "x")
      send_keys_sync(ctx, "y")
      assert_receive {:fake_task_stopped, ^working, {"fake", "request-1"}}
      assert TasksDrawer.selected(drawer(ctx)).state == :stopped
    end

    test "r on a waiting task retries now", %{ctx: ctx} do
      waiting = FakeTaskSession.start(ctx.editor, "Picker sources", :waiting, observer: self())
      send_keys_sync(ctx, "<Space>aa")
      send_keys_sync(ctx, "r")
      assert_receive {:fake_task_continued, ^waiting}
    end

    test "a stopped task offers Continue, and r continues it", %{ctx: ctx} do
      stopped = FakeTaskSession.start(ctx.editor, "Queue buffer", :stopped, observer: self())
      send_keys_sync(ctx, "<Space>aa")

      assert %{state: :stopped, words: "Stopped", actions: [{"r", "Continue"}, {"o", "Output"}]} =
               TasksDrawer.selected(drawer(ctx))

      send_keys_sync(ctx, "r")
      assert_receive {:fake_task_continued, ^stopped}
    end

    test "c opens the New task prompt, and esc returns to the drawer", %{ctx: ctx} do
      send_keys_sync(ctx, "<Space>aa")
      send_keys_sync(ctx, "c")

      model = StoryboardSession.model(session(ctx))
      assert model.minibuffer_prompt =~ "New task ›"

      send_keys_sync(ctx, "<Esc>")
      assert drawer(ctx).visible? and drawer(ctx).focused?
    end

    test "letters are ignored while a drawer that opened on its own is arming", %{ctx: ctx} do
      asking = FakeTaskSession.start(ctx.editor, "Add tests", :needs_you, observer: self())

      :sys.replace_state(
        ctx.editor,
        &MingaEditor.Shell.Traditional.TasksDrawerWorkflow.open_on(&1, asking)
      )

      send_keys_sync(ctx, "y")
      refute_received {:fake_task_answered, _pid, _decision}
    end
  end

  describe "acting on the task you saw" do
    test "a key on a selected row that went away answers nothing", %{ctx: ctx} do
      first = FakeTaskSession.start(ctx.editor, "First", :needs_you, observer: self())
      second = FakeTaskSession.start(ctx.editor, "Second", :needs_you, observer: self())
      send_keys_sync(ctx, "<Space>aa")
      send_keys_sync(ctx, "j")
      gone = TasksDrawer.selected(drawer(ctx))

      [vanishing, _other] = if gone.title == "Second", do: [second, first], else: [first, second]

      send(
        ctx.editor,
        {:minga_event, :agent_session_stopped,
         %MingaAgent.SessionManager.SessionStoppedEvent{
           session_id: "s",
           pid: vanishing,
           reason: :normal
         }}
      )

      send_keys_sync(ctx, "y")
      refute_received {:fake_task_answered, _pid, _decision}
    end

    test "a click on a row that went away does nothing", %{ctx: ctx} do
      FakeTaskSession.start(ctx.editor, "Asking", :needs_you, observer: self())
      send_keys_sync(ctx, "<Space>aa")
      send_gui_action(ctx, {:tasks_drawer_action, "t999", "y"})
      refute_received {:fake_task_answered, _pid, _decision}
    end

    test "a click on another row leaves a pending stop unanswered", %{ctx: ctx} do
      FakeTaskSession.start(ctx.editor, "Working", :working, observer: self())
      asking = FakeTaskSession.start(ctx.editor, "Asking", :needs_you, observer: self())
      send_keys_sync(ctx, "<Space>aa")
      send_keys_sync(ctx, "j")
      send_keys_sync(ctx, "x")
      assert drawer(ctx).prompt =~ "Stop “Working”?"

      row = Enum.find(drawer(ctx).rows, &(&1.state == :needs_you))
      send_gui_action(ctx, {:tasks_drawer_action, row.id, "y"})

      assert_receive {:fake_task_answered, ^asking, :approve}
      refute_received {:fake_task_stopped, _pid, _target}
      assert drawer(ctx).prompt == ""
    end

    test "y stops the turn the task showed when you pressed x", %{ctx: ctx} do
      working = FakeTaskSession.start(ctx.editor, "Working", :working, observer: self())
      send_keys_sync(ctx, "<Space>aa")
      send_keys_sync(ctx, "x")
      send(ctx.editor, {:agent_event, working, {:stop_target_changed, {"fake", "request-2"}}})
      send_keys_sync(ctx, "y")
      assert_receive {:fake_task_stopped, ^working, {"fake", "request-1"}}
    end
  end

  describe "a click on a needs-you alert" do
    # The suite turns agent alerts off globally; this editor reads its own options, with the terminal bell on.
    defp alerting_editor do
      options = start_supervised!({Minga.Config.Options, name: nil}, id: make_ref())
      {:ok, _} = Minga.Config.Options.set(options, :agent_notify_terminal, :bell)
      ctx = start_editor("hello world", options_server: options)
      Minga.Events.subscribe(:agent_desktop_notification, registry: ctx.events_registry)
      send(ctx.editor, {:minga_input, {:frontend_foreground, :background}})
      ctx
    end

    test "opens the drawer with the keyboard on that alert's task, and answers nothing" do
      ctx = alerting_editor()
      first = FakeTaskSession.start(ctx.editor, "First", :needs_you, observer: self())

      assert_receive {:minga_event, :agent_desktop_notification,
                      %{kind: :needs_you, id: id, owner: ^first}}

      # The newer task sorts first, so landing on "First" is the alert's identity, not the drawer's default.
      FakeTaskSession.start(ctx.editor, "Second", :needs_you, observer: self())
      assert_receive {:minga_event, :agent_desktop_notification, %{kind: :needs_you}}
      send_keys_sync(ctx, "<Space>aa")
      assert selected_title(drawer(ctx)) == "Second"
      send_keys_sync(ctx, "<Space>aa")

      send_gui_action(ctx, {:agent_notification_open, id})

      model = drawer(ctx)
      assert model.visible? and model.focused?
      assert selected_title(model) == "First"
      refute_received {:fake_task_answered, _pid, _decision}

      # The drawer opened on its own, so a letter typed right after the click answers nothing.
      send_keys_sync(ctx, "y")
      refute_received {:fake_task_answered, _pid, _decision}
    end

    test "an alert answered elsewhere lands on its task as it is now" do
      ctx = alerting_editor()
      asking = FakeTaskSession.start(ctx.editor, "Asking", :needs_you, observer: self())
      FakeTaskSession.start(ctx.editor, "Other", :needs_you)

      assert_receive {:minga_event, :agent_desktop_notification,
                      %{kind: :needs_you, id: id, owner: ^asking}}

      approval = FakeTaskSession.approval(asking)
      send(ctx.editor, {:agent_event, asking, {:approval_resolved, approval.target, :approve}})
      assert_receive {:minga_event, :agent_desktop_notification, %{kind: :withdrawn, id: ^id}}

      send_gui_action(ctx, {:agent_notification_open, id})

      model = drawer(ctx)
      assert model.visible?
      assert %{title: "Asking"} = selected = TasksDrawer.selected(model)
      refute selected.state == :needs_you
      refute_received {:fake_task_answered, _pid, _decision}
    end

    test "an alert Minga no longer knows opens the drawer on the first task that needs you" do
      ctx = alerting_editor()
      FakeTaskSession.start(ctx.editor, "Done", :done)
      FakeTaskSession.start(ctx.editor, "Asking", :needs_you)

      send_gui_action(ctx, {:agent_notification_open, <<7::128>>})

      model = drawer(ctx)
      assert model.visible? and model.focused?
      assert selected_title(model) == "Asking"
    end
  end

  describe "the keyboard comes back" do
    test "ctrl-g gives the keyboard back to the window and the drawer stays on screen", %{
      ctx: ctx
    } do
      send_keys_sync(ctx, "<Space>aa")
      send_key_sync(ctx, 7, 0)
      model = drawer(ctx)
      assert model.visible?
      refute model.focused?
      send_keys_sync(ctx, "x")
      assert buffer_content(ctx) == "ello world"
    end

    test "clicking a row from Insert leaves Insert first, so letters act on the drawer", %{
      ctx: ctx
    } do
      FakeTaskSession.start(ctx.editor, "Asking", :needs_you)
      send_keys_sync(ctx, "<Space>aa")
      row = TasksDrawer.selected(drawer(ctx))
      send_key_sync(ctx, 7, 0)
      send_keys_sync(ctx, "i")
      assert editor_mode(ctx) == :insert

      send_gui_action(ctx, {:tasks_drawer_action, row.id, "select"})

      assert editor_mode(ctx) == :normal
      assert drawer(ctx).focused?
      send_keys_sync(ctx, "x")
      assert buffer_content(ctx) == "hello world"
    end

    test "clicking the drawer's empty space from Insert gives it the keyboard and keeps the selection",
         %{
           ctx: ctx
         } do
      FakeTaskSession.start(ctx.editor, "Asking", :needs_you)
      FakeTaskSession.start(ctx.editor, "Docs", :done)
      send_keys_sync(ctx, "<Space>aa")
      send_keys_sync(ctx, "j")
      send_key_sync(ctx, 7, 0)
      send_keys_sync(ctx, "i")
      assert editor_mode(ctx) == :insert

      send_gui_action(ctx, {:tasks_drawer_action, "", "focus"})

      assert editor_mode(ctx) == :normal
      assert drawer(ctx).focused?
      assert selected_title(drawer(ctx)) == "Docs"
      send_keys_sync(ctx, "k")
      assert selected_title(drawer(ctx)) == "Asking"
      assert buffer_content(ctx) == "hello world"
    end

    test "a focus click with no drawer on screen does nothing", %{ctx: ctx} do
      send_keys_sync(ctx, "i")
      send_gui_action(ctx, {:tasks_drawer_action, "", "focus"})
      assert editor_mode(ctx) == :insert
      refute drawer(ctx).visible?
    end
  end

  describe "opening lands on the task that needs you" do
    test "a drawer opened again starts on the first needs-you row, not the row left selected", %{
      ctx: ctx
    } do
      FakeTaskSession.start(ctx.editor, "Docs", :done)
      send_keys_sync(ctx, "<Space>aa")
      assert selected_title(drawer(ctx)) == "Docs"
      send_keys_sync(ctx, "q")

      FakeTaskSession.start(ctx.editor, "Asking", :needs_you)
      send_keys_sync(ctx, "<Space>aa")
      assert selected_title(drawer(ctx)) == "Asking"
    end

    test "a drawer on screen that takes the keyboard back keeps its selection", %{ctx: ctx} do
      FakeTaskSession.start(ctx.editor, "Asking", :needs_you)
      FakeTaskSession.start(ctx.editor, "Docs", :done)
      send_keys_sync(ctx, "<Space>aa")
      send_keys_sync(ctx, "j")
      send_key_sync(ctx, 7, 0)
      refute drawer(ctx).focused?

      send_keys_sync(ctx, "<Space>aa")
      assert drawer(ctx).focused?
      assert selected_title(drawer(ctx)) == "Docs"
    end
  end

  test "]h and [h step between runs of changed lines" do
    lines = [" keep", "+ one", "+ two", " keep", "- three", " keep"]
    assert MingaEditor.Shell.Traditional.TasksDrawerWorkflow.change_starts(lines) == [1, 4]
  end

  defp session(ctx),
    do: %StoryboardSession{ctx: ctx, root: "", file: "", home_window: 0, child_id: make_ref()}
end
