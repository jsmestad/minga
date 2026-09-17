defmodule MingaEditor.State.FrontendFileDialogTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Frontend

  test "correlates one request at a time and ignores stale results" do
    assert {:ok, 1, pending} = Frontend.begin_file_dialog(%Frontend{}, :open)
    assert pending.file_dialog == {:open, 1}
    assert {:error, :busy} = Frontend.begin_file_dialog(pending, :open)
    assert :stale = Frontend.take_file_dialog(pending, 2)
    assert {:ok, {:open, 1}, idle} = Frontend.take_file_dialog(pending, 1)
    assert idle.file_dialog == :idle
    assert idle.next_file_dialog_request_id == 2
  end

  test "retains the Save As buffer and does not reuse a wrapped request id" do
    frontend = %Frontend{next_file_dialog_request_id: 0xFFFFFFFF}
    assert {:ok, 0xFFFFFFFF, pending} = Frontend.begin_file_dialog(frontend, {:save_as, self()})
    assert pending.file_dialog == {:save_as, 0xFFFFFFFF, self()}
    assert pending.next_file_dialog_request_id == 1
    assert Frontend.clear_file_dialog(pending).file_dialog == :idle
  end
end
