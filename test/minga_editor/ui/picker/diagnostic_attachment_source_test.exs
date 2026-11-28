defmodule MingaEditor.UI.Picker.DiagnosticAttachmentSourceTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic
  alias Minga.LSP.SyncServer
  alias MingaEditor.Input.ActMenu, as: ActInput
  alias MingaEditor.Mouse
  alias MingaEditor.Mouse.Target.Text, as: TextTarget
  alias MingaEditor.Mouse.TextEvent
  alias MingaEditor.Shell.Traditional.{ActMenu, ActMenuWorkflow, NoticeWorkflow}
  alias MingaEditor.State.Windows
  alias MingaEditor.UI.Picker.DiagnosticAttachmentSource
  alias MingaEditor.Window

  import MingaEditor.RenderPipeline.TestHelpers, only: [gui_state: 0]

  @moduletag :tmp_dir

  test "secondary click away from a diagnostic attaches the displayed file, not the focused file",
       %{tmp_dir: dir} do
    path = Path.join(dir, "right.txt")
    File.write!(path, "right pane\nwith diagnostics\n")
    publish_warning(path)
    buffer = start_supervised!({BufferProcess, file_path: path})
    state = inactive_pane(buffer)
    version = BufferProcess.version(buffer)

    target =
      TextTarget.new(%{window_id: 2, buffer: buffer, source_version: version, line: 0, byte: 1})

    event =
      TextEvent.new(%{
        window_id: 2,
        presentation_id: 7,
        row_index: 0,
        row_id: 22,
        utf16_offset: 1,
        button: :right,
        mods: 0,
        event_type: :press,
        click_count: 1,
        scroll_x: 0,
        scroll_y: 0
      })

    clicked = Mouse.handle_text_event(state, event, target)

    assert %{title: "right.txt"} = clicked |> ActMenuWorkflow.current() |> ActMenu.model()
    assert {:handled, attached} = ActInput.handle_key(clicked, ?d, 0)

    assert {:picker, %{picker_ui: %{context: %{path: ^path}}}} =
             attached.shell_runtime.state.modal

    :ok = BufferProcess.insert_text(buffer, "changed")
    assert {:handled, stale} = ActInput.handle_key(clicked, ?d, 0)
    assert stale.shell_runtime.state.modal == state.shell_runtime.state.modal
    assert NoticeWorkflow.message(stale) == "The target changed. Open the act menu again."
  end

  test "a remote pane cannot use the local diagnostic identity for the same path", %{tmp_dir: dir} do
    path = Path.join(dir, "same.txt")
    File.write!(path, "local text")
    publish_warning(path)

    remote = start_supervised!({BufferProcess, file_path: path, storage: {:remote, node(), path}})

    state = inactive_pane(remote)
    rejected = DiagnosticAttachmentSource.open_buffer(state, remote)
    assert rejected.shell_runtime.state.modal == state.shell_runtime.state.modal

    assert NoticeWorkflow.message(rejected) ==
             "Diagnostics snapshots are only available for local files."
  end

  defp inactive_pane(buffer) do
    state = gui_state()
    windows = Windows.add_window(state.workspace.windows, Window.new(2, buffer, 24, 80))
    %{state | workspace: %{state.workspace | windows: windows}}
  end

  defp publish_warning(path) do
    uri = SyncServer.path_to_uri(path)

    :ok =
      Diagnostics.publish(:diagnostic_attachment_test, uri, [
        %Diagnostic{
          range: %{start_line: 1, start_col: 0, end_line: 1, end_col: 1},
          severity: :warning,
          message: "Diagnostic on the second line"
        }
      ])

    on_exit(fn -> Diagnostics.publish(:diagnostic_attachment_test, uri, []) end)
  end
end
