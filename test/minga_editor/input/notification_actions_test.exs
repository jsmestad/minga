defmodule MingaEditor.Input.NotificationActionsTest do
  # async: false - this suite shells out via CommandOutput.Port and must not run
  # concurrently with other OS-process tests that use the same BEAM child setup.
  use Minga.Test.EditorCase, async: false

  @moduletag :heavy

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.CommandOutput
  alias Minga.Events

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

  test "retry action reruns the last test command" do
    ctx = start_editor("hello")
    Events.subscribe(:command_done, registry: ctx.events_registry)

    :ok =
      CommandOutput.run("*test*", "bash -c 'echo first; exit 1'",
        events_registry: ctx.events_registry
      )

    await_command_done("*test*", 1)

    :sys.replace_state(ctx.editor, fn state ->
      %{
        state
        | session:
            MingaEditor.State.Session.remember_test_command(state.session, {"echo rerun", "."})
      }
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
