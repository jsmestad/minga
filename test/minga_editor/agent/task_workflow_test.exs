defmodule MingaEditor.Agent.TaskWorkflowTest do
  @moduledoc """
  The Editor keeps every session it follows as a task, including the approval of a session no tab shows, and alerts you once when a task starts needing you while Minga is in the background.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Config.Options
  alias Minga.Test.FakeTaskSession
  alias MingaAgent.ToolApproval.Preview
  alias MingaAgent.ToolApproval.Public
  alias MingaAgent.ToolApproval.Target
  alias MingaEditor.Agent.Tasks
  alias MingaEditor.Agent.Tasks.Entry

  defp tasks(%{editor: editor}), do: :sys.get_state(editor).agent_connection.tasks

  test "a background session's approval is kept on its task until the session resolves it" do
    ctx = start_editor("hello")
    session = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(session, :kill) end)

    approval =
      Public.new(
        Target.new("background", "request-1", "call-1"),
        "write_file",
        %{"path" => "lib/a.ex"},
        Preview.new(:diff, "Edit lib/a.ex +2", [])
      )

    send(ctx.editor, {:agent_event, session, {:credentials_status, true}})
    send(ctx.editor, {:agent_event, session, {:status_changed, :tool_executing}})
    send(ctx.editor, {:agent_event, session, {:approval_pending, approval}})

    assert {:ok, %Entry{} = entry} = ctx |> tasks() |> Tasks.fetch(session)
    assert Entry.state(entry) == :needs_you
    assert Tasks.needs_you_count(tasks(ctx)) == 1

    send(ctx.editor, {:agent_event, session, {:approval_resolved, approval.target, :approve}})
    assert Tasks.approval(tasks(ctx), session) == nil
  end

  test "a session that stops is no longer a task" do
    ctx = start_editor("hello")
    session = spawn(fn -> :ok end)

    send(ctx.editor, {:agent_event, session, {:credentials_status, true}})
    assert {:ok, _entry} = ctx |> tasks() |> Tasks.fetch(session)

    send(
      ctx.editor,
      {:minga_event, :agent_session_stopped,
       %MingaAgent.SessionManager.SessionStoppedEvent{
         session_id: "s",
         pid: session,
         reason: :normal
       }}
    )

    assert Tasks.fetch(tasks(ctx), session) == :error
  end

  describe "the needs-you alert" do
    # The suite turns agent alerts off globally; each editor here reads its own options, with the terminal bell on.
    defp alerting_editor(terminal \\ :bell) do
      options = start_supervised!({Options, name: nil}, id: make_ref())
      {:ok, _} = Options.set(options, :agent_notify_terminal, terminal)
      ctx = start_editor("hello", options_server: options)
      Minga.Events.subscribe(:agent_desktop_notification, registry: ctx.events_registry)
      ctx
    end

    defp foreground(ctx, status),
      do: send(ctx.editor, {:minga_input, {:frontend_foreground, status}})

    test "a task that starts needing you in the background alerts once, and answering it withdraws the alert" do
      ctx = alerting_editor()
      foreground(ctx, :background)
      asking = FakeTaskSession.start(ctx.editor, "Add tests", :needs_you)

      assert_receive {:minga_event, :agent_desktop_notification,
                      %{kind: :needs_you, id: <<_::128>> = id, owner: ^asking}}

      # Still needing you: a question while the approval is pending, and more work, alert nothing more.
      send(ctx.editor, {:agent_event, asking, {:question_requested, {"q", 1}, %{}}})
      send(ctx.editor, {:agent_event, asking, :output_streamed})
      _ = tasks(ctx)
      refute_received {:minga_event, :agent_desktop_notification, %{kind: :needs_you}}

      send(ctx.editor, {:agent_event, asking, {:question_answered, {"q", 1}}})
      approval = FakeTaskSession.approval(asking)
      send(ctx.editor, {:agent_event, asking, {:approval_resolved, approval.target, :approve}})

      assert_receive {:minga_event, :agent_desktop_notification,
                      %{kind: :withdrawn, id: ^id, owner: ^asking}}

      refute_received {:minga_event, :agent_desktop_notification, _alert}
    end

    test "an approval answered in the drawer withdraws its alert once" do
      ctx = alerting_editor()
      foreground(ctx, :background)
      asking = FakeTaskSession.start(ctx.editor, "Add tests", :needs_you)
      assert_receive {:minga_event, :agent_desktop_notification, %{kind: :needs_you, id: id}}

      :sys.replace_state(ctx.editor, &MingaEditor.Agent.TaskWorkflow.answer(&1, asking, :approve))
      _ = tasks(ctx)

      assert_receive {:minga_event, :agent_desktop_notification, %{kind: :withdrawn, id: ^id}}
      refute_received {:minga_event, :agent_desktop_notification, _alert}
    end

    test "a session that stops being followed while it needs you withdraws its alert, even though it lives on" do
      ctx = alerting_editor()
      foreground(ctx, :background)
      asking = FakeTaskSession.start(ctx.editor, "Add tests", :needs_you)
      assert_receive {:minga_event, :agent_desktop_notification, %{kind: :needs_you, id: id}}

      # A detached remote session stays alive, so the frontend's monitor on it never fires.
      :sys.replace_state(ctx.editor, &MingaEditor.Agent.TaskWorkflow.stopped(&1, asking))

      assert_receive {:minga_event, :agent_desktop_notification,
                      %{kind: :withdrawn, id: ^id, owner: ^asking}}

      assert :error = ctx |> tasks() |> Tasks.fetch(asking)
    end

    test "a task that needs you while Minga is in the foreground, or cannot tell, alerts nothing" do
      ctx = alerting_editor()

      # No report yet: the foreground is unknown, which counts as the foreground.
      FakeTaskSession.start(ctx.editor, "Unknown", :needs_you)
      foreground(ctx, :foreground)
      looking = FakeTaskSession.start(ctx.editor, "Looking", :needs_you)
      _ = tasks(ctx)
      refute_received {:minga_event, :agent_desktop_notification, _alert}

      # Going to the background later does not alert for a task that already needed you.
      foreground(ctx, :background)
      send(ctx.editor, {:agent_event, looking, :output_streamed})
      _ = tasks(ctx)
      refute_received {:minga_event, :agent_desktop_notification, _alert}

      # Resolving an approval that never alerted withdraws nothing.
      approval = FakeTaskSession.approval(looking)
      send(ctx.editor, {:agent_event, looking, {:approval_resolved, approval.target, :approve}})
      _ = tasks(ctx)
      refute_received {:minga_event, :agent_desktop_notification, _alert}
    end

    test "the terminal alerts nothing unless :agent_notify_terminal asks for it" do
      ctx = alerting_editor(:off)
      foreground(ctx, :background)
      asking = FakeTaskSession.start(ctx.editor, "Add tests", :needs_you)

      assert {:ok, %Entry{alert: nil}} = ctx |> tasks() |> Tasks.fetch(asking)
      refute_received {:minga_event, :agent_desktop_notification, _alert}
    end
  end
end
