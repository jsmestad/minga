defmodule Minga.Editor.EnsureBufferTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor

  @moduletag :tmp_dir

  describe "ensure_buffer_for_path/2" do
    test "returns existing pid if buffer already registered", %{tmp_dir: dir} do
      path = Path.join(dir, "existing.ex")
      File.write!(path, "defmodule Existing do\nend\n")
      pid = start_supervised!({BufferServer, file_path: path})

      assert {:ok, ^pid} = Editor.ensure_buffer_for_path(path)
    end

    test "returns error for nonexistent file when no buffer registered", %{tmp_dir: dir} do
      path = Path.join(dir, "nonexistent.ex")

      # Buffer.ensure_for_path checks File.exists? before starting a buffer.
      # No buffer exists and the file doesn't exist on disk, so we get :enoent.
      assert {:error, :enoent} = Editor.ensure_buffer_for_path(path)
    end

    test "skips GenServer call when buffer is already in the Registry", %{tmp_dir: dir} do
      # Verifies the fast path: pid_for_path succeeds, no Editor call needed.
      # This works even without a running Editor.
      path = Path.join(dir, "fast_path.ex")
      File.write!(path, "content")
      pid = start_supervised!({BufferServer, file_path: path})

      # Call multiple times to verify idempotency
      assert {:ok, ^pid} = Editor.ensure_buffer_for_path(path)
      assert {:ok, ^pid} = Editor.ensure_buffer_for_path(path)
    end
  end

  # NOTE: ensure_buffer_for_path now delegates to Buffer.ensure_for_path
  # (Layer 1) for the actual buffer start, then casts to the Editor for
  # workspace registration. This means it works even without a running
  # Editor: the buffer starts, and the cast to register it is a no-op.
  # Full integration coverage lives in the snapshot test suite.
end
