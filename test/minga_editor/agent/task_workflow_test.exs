defmodule MingaEditor.Agent.TaskWorkflowTest do
  @moduledoc """
  The Editor keeps every session it follows as a task, including the approval of a session no tab shows.
  """

  use Minga.Test.EditorCase, async: true

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
end
