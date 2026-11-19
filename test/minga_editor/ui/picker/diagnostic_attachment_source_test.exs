defmodule MingaEditor.UI.Picker.DiagnosticAttachmentSourceTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic
  alias Minga.LSP.SyncServer
  alias MingaEditor.Renderer.{TextInteractionIndex, TextPresentation}
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State.Windows
  alias MingaEditor.UI.Picker.DiagnosticAttachmentSource
  alias MingaEditor.Window

  import MingaEditor.RenderPipeline.TestHelpers, only: [gui_state: 0]

  @moduletag :tmp_dir

  test "a menu resolves the displayed inactive pane and refuses its retired presentation", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "right.txt")
    File.write!(path, "right pane")
    buffer = start_supervised!({BufferProcess, file_path: path})
    {state, index} = present_inactive(buffer)

    clicked = DiagnosticAttachmentSource.open_presented(state, "2:7")
    assert {:picker, %{picker_ui: %{context: %{path: ^path}}}} = clicked.shell_runtime.state.modal

    index =
      TextInteractionIndex.publish(
        index,
        TextPresentation.new(2, buffer, 0, :new, {:windowed, []}, 8)
      )

    :ok = TextInteractionIndex.activate(index, 2, 8)

    stale = DiagnosticAttachmentSource.open_presented(state, "2:7")
    assert stale.shell_runtime.state.modal == state.shell_runtime.state.modal
    assert NoticeWorkflow.message(stale) == "This editor pane changed. Open the menu again."
  end

  test "a remote pane cannot use the local diagnostic identity for the same path", %{tmp_dir: dir} do
    path = Path.join(dir, "same.txt")
    File.write!(path, "local text")
    uri = SyncServer.path_to_uri(path)

    :ok =
      Diagnostics.publish(:diagnostic_attachment_test, uri, [
        %Diagnostic{
          range: %{start_line: 0, start_col: 0, end_line: 0, end_col: 1},
          severity: :warning,
          message: "Local diagnostic for this same path"
        }
      ])

    on_exit(fn -> Diagnostics.publish(:diagnostic_attachment_test, uri, []) end)

    remote = start_supervised!({BufferProcess, file_path: path, storage: {:remote, node(), path}})

    {state, _index} = present_inactive(remote)

    rejected = DiagnosticAttachmentSource.open_presented(state, "2:7")
    assert rejected.shell_runtime.state.modal == state.shell_runtime.state.modal

    assert NoticeWorkflow.message(rejected) ==
             "Diagnostics snapshots are only available for local files."
  end

  defp present_inactive(buffer) do
    state = gui_state()
    windows = Windows.add_window(state.workspace.windows, Window.new(2, buffer, 24, 80))
    presentation = TextPresentation.new(2, buffer, 0, :original, {:windowed, []}, 7)
    index = TextInteractionIndex.publish(TextInteractionIndex.new(), presentation)
    :ok = TextInteractionIndex.activate(index, 2, 7)

    {%{
       state
       | workspace: %{state.workspace | windows: windows},
         render: %{state.render | text_interaction_reader: TextInteractionIndex.reader(index)}
     }, index}
  end
end
