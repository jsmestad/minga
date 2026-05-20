defmodule Minga.Project.FileRefTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Project.FileRef

  describe "from_path/2" do
    test "keys path refs by expanded project root and normalized relative path" do
      root = Path.join(System.tmp_dir!(), "minga-file-ref-root")

      assert {:ok, ref} = FileRef.from_path(root, "lib/../lib/user.ex")
      assert ref.kind == :path
      assert ref.project_root == Path.expand(root)
      assert ref.relative_path == "lib/user.ex"
      assert ref.display_name == "user.ex"
      assert ref.buffer_pid == nil
    end

    test "accepts absolute paths inside the project root" do
      root = Path.join(System.tmp_dir!(), "minga-file-ref-root")
      path = Path.join([root, "apps", "web", "user.ex"])

      assert {:ok, ref} = FileRef.from_path(root, path)
      assert ref.relative_path == "apps/web/user.ex"
      assert ref.display_name == "user.ex"
    end

    test "rejects paths that escape the project root" do
      root = Path.join(System.tmp_dir!(), "minga-file-ref-root")

      assert FileRef.from_path(root, "../outside.ex") == {:error, :outside_project}
    end

    test "duplicate basenames in different directories remain distinct refs" do
      root = Path.join(System.tmp_dir!(), "minga-file-ref-root")

      assert {:ok, lib_ref} = FileRef.from_path(root, "lib/user.ex")
      assert {:ok, test_ref} = FileRef.from_path(root, "test/user.ex")

      refute FileRef.equal?(lib_ref, test_ref)
      assert FileRef.display_label(lib_ref) == "user.ex"
      assert FileRef.display_label(test_ref) == "user.ex"
    end
  end

  describe "from_buffer/1" do
    test "represents unsaved buffers as buffer refs" do
      {:ok, buffer} =
        start_supervised({BufferProcess, content: "scratch", buffer_name: "*scratch*"})

      ref = FileRef.from_buffer(buffer)

      assert ref.kind == :buffer
      assert ref.project_root == nil
      assert ref.relative_path == nil
      assert ref.display_name == "*scratch*"
      assert ref.buffer_pid == buffer
    end
  end

  describe "equal?/2" do
    test "matches path refs by root and relative path" do
      root = Path.join(System.tmp_dir!(), "minga-file-ref-root")

      assert {:ok, ref_a} = FileRef.from_path(root, "lib/thing.ex")
      assert {:ok, ref_b} = FileRef.from_path(Path.expand(root), "lib/thing.ex")

      assert FileRef.equal?(ref_a, ref_b)
    end

    test "matches buffer refs by pid" do
      {:ok, buffer} =
        start_supervised({BufferProcess, content: "scratch", buffer_name: "*scratch*"})

      assert FileRef.equal?(FileRef.from_buffer(buffer), FileRef.from_buffer(buffer))
    end
  end
end
