defmodule MingaEditor.Handlers.GuiActionVolumeUnmountTest do
  @moduledoc """
  Tests for handling `NSWorkspace.willUnmountNotification` forwarded from the GUI.

  Uses the global `Minga.Buffer.Registry`, but async is safe because
  `buffers_under_prefix/1` filters by the full tmp_dir path, which is
  unique per test. The global Registry scan cannot match buffers from
  concurrent tests.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.RenderPipeline.TestHelpers

  @moduletag :tmp_dir

  setup do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})
    %{sidebar_registry: table}
  end

  defp base_state(sidebar_registry) do
    TestHelpers.base_state(sidebar_registry: sidebar_registry)
  end

  defp start_file_buffer(path) do
    start_supervised!({BufferProcess, file_path: path}, id: make_ref())
  end

  test "saves dirty buffers and marks them read-only when their volume unmounts", %{
    tmp_dir: dir,
    sidebar_registry: table
  } do
    volume = Path.join(dir, "MountedVolume")
    File.mkdir_p!(volume)
    path = Path.join(volume, "doc.txt")
    File.write!(path, "original")

    buf = start_file_buffer(path)
    :ok = BufferProcess.insert_text(buf, " EDITED")
    assert Buffer.dirty?(buf)
    refute Buffer.read_only?(buf)

    state = base_state(table)
    new_state = GuiActionHandler.dispatch(state, {:system_will_unmount, volume})

    # Unsaved work was flushed to disk before the volume goes away.
    assert File.read!(path) =~ "EDITED"
    # The buffer is now disconnected: further writes are rejected.
    assert Buffer.read_only?(buf)
    assert {:error, :read_only} = BufferProcess.insert_text(buf, "MORE")

    status = MingaEditor.Shell.Traditional.NoticeWorkflow.message(new_state)
    assert status =~ "Volume unmounted"
    assert status =~ volume
  end

  test "leaves buffers on other volumes untouched", %{tmp_dir: dir, sidebar_registry: table} do
    unmounting = Path.join(dir, "Unmounting")
    other = Path.join(dir, "Other")
    File.mkdir_p!(unmounting)
    File.mkdir_p!(other)

    other_path = Path.join(other, "safe.txt")
    File.write!(other_path, "original")
    other_buf = start_file_buffer(other_path)
    :ok = BufferProcess.insert_text(other_buf, " STILL_DIRTY")

    state = base_state(table)
    _ = GuiActionHandler.dispatch(state, {:system_will_unmount, unmounting})

    # The buffer on the other volume is unaffected: still dirty, still writable.
    assert Buffer.dirty?(other_buf)
    refute Buffer.read_only?(other_buf)
    assert File.read!(other_path) == "original"
  end

  test "does not match a sibling volume sharing a name prefix", %{
    tmp_dir: dir,
    sidebar_registry: table
  } do
    File.mkdir_p!(Path.join(dir, "USB"))
    sibling = Path.join(dir, "USB2")
    File.mkdir_p!(sibling)

    sibling_path = Path.join(sibling, "file.txt")
    File.write!(sibling_path, "original")
    sibling_buf = start_file_buffer(sibling_path)
    :ok = BufferProcess.insert_text(sibling_buf, " EDIT")

    state = base_state(table)
    # Unmount "USB"; "USB2" must not be treated as living under it.
    _ = GuiActionHandler.dispatch(state, {:system_will_unmount, Path.join(dir, "USB")})

    refute Buffer.read_only?(sibling_buf)
    assert Buffer.dirty?(sibling_buf)
  end

  test "no open buffers under the volume is a no-op with no status noise", %{
    tmp_dir: dir,
    sidebar_registry: table
  } do
    state = base_state(table)
    new_state = GuiActionHandler.dispatch(state, {:system_will_unmount, Path.join(dir, "Empty")})

    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(new_state) ==
             MingaEditor.Shell.Traditional.NoticeWorkflow.message(state)
  end
end
