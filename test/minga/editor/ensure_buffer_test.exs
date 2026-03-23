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

    test "exits when Editor not running and no buffer registered", %{tmp_dir: dir} do
      path = Path.join(dir, "nonexistent.ex")

      # Editor isn't running in tests. pid_for_path returns :not_found,
      # then the GenServer.call to the Editor exits.
      assert {:noproc, _} = catch_exit(Editor.ensure_buffer_for_path(path))
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

  # NOTE: The handle_call({:ensure_buffer, path}) path requires a running
  # Editor GenServer, which depends on the full supervision tree (Port.Manager,
  # Parser.Manager, Config.Options, etc.). No existing tests in the project
  # start a real Editor. The auto-open path composes three well-tested
  # primitives:
  #   1. BufferServer.pid_for_path/1 (tested in server_test.exs)
  #   2. Commands.start_buffer/1 (used by :edit, file_tree, LSP go-to-def)
  #   3. register_buffer_background/3 which calls:
  #      - Buffers.add_background/2 (tested in buffers_test.exs)
  #      - EditorState.monitor_buffer/2 (tested in editor state tests)
  #      - LSP status is event-driven via :lsp_status_changed (tested in LSP tests)
  #      - Events.broadcast/2 (tested in events tests)
  #
  # Full integration coverage lives in the snapshot test suite which
  # exercises the Editor end-to-end with real rendering.
end
