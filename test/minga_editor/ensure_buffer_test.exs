defmodule MingaEditor.EnsureBufferTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor

  @moduletag :tmp_dir

  describe "ensure_buffer_for_path/2" do
    test "returns existing pid if buffer already registered", %{tmp_dir: dir} do
      path = Path.join(dir, "existing.ex")
      File.write!(path, "defmodule Existing do\nend\n")
      pid = start_supervised!({BufferProcess, file_path: path})

      assert {:ok, ^pid} = MingaEditor.ensure_buffer_for_path(path)
    end

    test "returns error for nonexistent file when no buffer registered", %{tmp_dir: dir} do
      path = Path.join(dir, "nonexistent.ex")

      # Buffer.ensure_for_path checks File.exists? before starting a buffer.
      # No buffer exists and the file doesn't exist on disk, so we get :enoent.
      assert {:error, :enoent} = MingaEditor.ensure_buffer_for_path(path)
    end

    test "starts a buffer for an existing file when no editor is running", %{tmp_dir: dir} do
      path = Path.join(dir, "no_editor.ex")
      File.write!(path, "defmodule NoEditor do\nend\n")

      assert {:ok, pid} = MingaEditor.ensure_buffer_for_path(path, :missing_minga_editor)

      monitor = Process.monitor(pid)
      assert Buffer.file_path(pid) == Path.expand(path)
      refute_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 0
      Process.demonitor(monitor, [:flush])
    end

    test "falls back when the supplied editor pid is already dead", %{tmp_dir: dir} do
      path = Path.join(dir, "dead_editor.ex")
      File.write!(path, "defmodule DeadEditor do\nend\n")
      {:ok, editor} = Agent.start_link(fn -> :ok end)
      editor_monitor = Process.monitor(editor)

      GenServer.stop(editor)
      assert_receive {:DOWN, ^editor_monitor, :process, ^editor, :normal}

      assert {:ok, pid} = MingaEditor.ensure_buffer_for_path(path, editor)

      buffer_monitor = Process.monitor(pid)
      assert Buffer.file_path(pid) == Path.expand(path)
      refute_receive {:DOWN, ^buffer_monitor, :process, ^pid, _reason}, 0
      Process.demonitor(buffer_monitor, [:flush])
    end

    test "skips GenServer call when buffer is already in the Registry", %{tmp_dir: dir} do
      # Verifies the fast path: pid_for_path succeeds, no Editor call needed.
      # This works even without a running Editor.
      path = Path.join(dir, "fast_path.ex")
      File.write!(path, "content")
      pid = start_supervised!({BufferProcess, file_path: path})

      # Call multiple times to verify idempotency
      assert {:ok, ^pid} = MingaEditor.ensure_buffer_for_path(path)
      assert {:ok, ^pid} = MingaEditor.ensure_buffer_for_path(path)
    end
  end

  # NOTE: ensure_buffer_for_path now delegates to Buffer.ensure_for_path
  # (Layer 1) for the actual buffer start, then casts to the Editor for
  # workspace registration. This means it works even without a running
  # Editor: the buffer starts, and the cast to register it is a no-op.
  # Full integration coverage lives in the snapshot test suite.
end
