defmodule MingaEditor.Input.NotificationActionsTest do
  # async: false - this suite shells out via CommandOutput.Port and must not run
  # concurrently with other OS-process tests that use the same BEAM child setup.
  use Minga.Test.EditorCase, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.CommandOutput
  alias Minga.Events
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Notification
  alias MingaEditor.UI.NotificationCenter

  setup do
    on_exit(fn ->
      _ = CommandOutput.kill("*test*")
    end)

    :ok
  end

  test "show_logs action opens the test output buffer" do
    ctx = start_editor("hello")
    Events.subscribe(:command_done, registry: ctx.events_registry)

    :ok =
      CommandOutput.run("*test*", "bash -c 'echo logs; exit 1'",
        events_registry: ctx.events_registry
      )

    await_command_done("*test*", 1)

    send(
      ctx.editor,
      {:minga_input, {:gui_action, {:notification_action, "build:test", "show_logs"}}}
    )

    _state = editor_state(ctx)

    assert BufferProcess.buffer_name(active_buffer(ctx)) == "*test*"
    assert BufferProcess.content(active_buffer(ctx)) =~ "$ bash -c 'echo logs; exit 1'"
    assert BufferProcess.content(active_buffer(ctx)) =~ "logs"
  end

  test "notification_dismiss gui_action removes only the selected notification" do
    ctx = start_editor("hello")

    :sys.replace_state(ctx.editor, fn state ->
      state
      |> EditorState.upsert_notification(
        Notification.new(
          id: "build:test",
          level: :progress,
          title: "Building Minga",
          created_at: 1_715_000_000
        )
      )
      |> EditorState.upsert_notification(
        Notification.new(
          id: "other",
          level: :info,
          title: "Still here",
          created_at: 1_715_000_010
        )
      )
    end)

    send(ctx.editor, {:minga_input, {:gui_action, {:notification_dismiss, "build:test"}}})

    state = editor_state(ctx)

    assert NotificationCenter.find(state.notifications, "build:test") == nil
    assert [%{id: "other"}] = NotificationCenter.list(state.notifications)
  end

  test "retry action reruns the last test command" do
    ctx = start_editor("hello")
    Events.subscribe(:command_done, registry: ctx.events_registry)

    :ok =
      CommandOutput.run("*test*", "bash -c 'echo first; exit 1'",
        events_registry: ctx.events_registry
      )

    await_command_done("*test*", 1)

    :sys.replace_state(ctx.editor, fn state ->
      EditorState.set_last_test_command(state, {"echo rerun", "."})
    end)

    send(ctx.editor, {:minga_input, {:gui_action, {:notification_action, "build:test", "retry"}}})
    await_command_done("*test*", 0)
    _state = editor_state(ctx)

    buffer = CommandOutput.buffer("*test*")
    assert is_pid(buffer)
    assert BufferProcess.content(buffer) =~ "$ echo rerun"
    assert BufferProcess.content(buffer) =~ "rerun"
  end

  defp await_command_done(name, exit_code, timeout \\ 2_000) do
    assert_receive {:minga_event, :command_done,
                    %Events.CommandDoneEvent{name: ^name, exit_code: ^exit_code}},
                   timeout
  end
end
