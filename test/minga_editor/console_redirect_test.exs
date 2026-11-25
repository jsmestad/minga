defmodule MingaEditor.ConsoleRedirectTest do
  # async: false because this editor owns the VM's console, which every other test in the VM shares.
  # It moves the real `:standard_error` to the log file and adds the log-file logger handler.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.LoggerHandler
  alias Minga.LoggerHandler.StderrRedirect
  alias Minga.Test.HeadlessPort

  test "after the editor that asked for the redirect is killed, standard error still writes to the log file" do
    original = Process.whereis(:standard_error)

    # Runs after ExUnit has put the default logger handler back, so `uninstall/0` finds it and leaves it alone.
    on_exit(fn ->
      LoggerHandler.uninstall()
      LoggerHandler.install_messages_handler()
    end)

    port = start_supervised!({HeadlessPort, width: 40, height: 10})
    buffer = start_supervised!({BufferProcess, content: "text"})
    name = :"console_redirect_editor_#{System.unique_integer([:positive])}"

    start_supervised!(
      {MingaEditor,
       name: name,
       backend: :tui,
       port_manager: port,
       buffer: buffer,
       width: 40,
       height: 10,
       editing_model: :vim,
       suppress_tool_prompts: true,
       startup_file: nil},
      id: :console_redirect_editor
    )

    editor = Process.whereis(name)
    assert StderrRedirect.redirected?()
    device = Process.whereis(:standard_error)
    assert device != original

    ref = Process.monitor(editor)
    Process.exit(editor, :kill)
    assert_receive {:DOWN, ^ref, :process, ^editor, :killed}

    marker = "written after the editor was killed #{System.unique_integer([:positive])}"
    assert :ok = IO.puts(:stderr, marker)

    assert Process.whereis(:standard_error) == device
    log_path = Path.join(Minga.UserPaths.data_dir(), "minga.log")
    assert File.read!(log_path) =~ marker

    # The supervisor starts the editor again, and a new editor asks for the redirect again. Stop it first.
    :ok = stop_supervised!(:console_redirect_editor)
    :ok = StderrRedirect.restore()
    assert Process.whereis(:standard_error) == original
  end
end
