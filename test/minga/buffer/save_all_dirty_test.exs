defmodule Minga.Buffer.SaveAllDirtyTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.Server

  @moduletag :tmp_dir

  defp start_file_buffer(path) do
    start_supervised!({Server, file_path: path}, id: make_ref())
  end

  describe "save_all_dirty/0" do
    test "saves dirty file-backed buffers to disk", %{tmp_dir: dir} do
      a_path = Path.join(dir, "a.txt")
      b_path = Path.join(dir, "b.txt")
      File.write!(a_path, "original_a")
      File.write!(b_path, "original_b")

      buf_a = start_file_buffer(a_path)
      buf_b = start_file_buffer(b_path)

      :ok = Server.insert_text(buf_a, " MODIFIED_A")
      :ok = Server.insert_text(buf_b, " MODIFIED_B")

      assert Server.dirty?(buf_a)
      assert Server.dirty?(buf_b)

      {saved, _warnings} = Buffer.save_all_dirty()

      # At least our two buffers were saved (others may exist from concurrent tests)
      assert saved >= 2
      assert File.read!(a_path) =~ "MODIFIED_A"
      assert File.read!(b_path) =~ "MODIFIED_B"
    end

    test "does not write clean buffers to disk", %{tmp_dir: dir} do
      path = Path.join(dir, "clean.txt")
      File.write!(path, "original")

      buf = start_file_buffer(path)
      refute Server.dirty?(buf)

      Buffer.save_all_dirty()

      assert File.read!(path) == "original"
    end

    test "one buffer failing does not block other saves", %{tmp_dir: dir} do
      writable_path = Path.join(dir, "writable.txt")
      readonly_path = Path.join(dir, "readonly.txt")
      File.write!(writable_path, "original")
      File.write!(readonly_path, "original")

      writable_buf = start_file_buffer(writable_path)
      readonly_buf = start_file_buffer(readonly_path)

      :ok = Server.insert_text(writable_buf, " MODIFIED")
      :ok = Server.insert_text(readonly_buf, " MODIFIED")

      # Make the file unwritable so save fails
      File.chmod!(readonly_path, 0o000)
      on_exit(fn -> File.chmod!(readonly_path, 0o644) end)

      {saved, warnings} = Buffer.save_all_dirty()

      # The writable buffer was saved successfully
      assert saved >= 1
      assert File.read!(writable_path) =~ "MODIFIED"

      # The readonly buffer produced a warning
      assert Enum.any?(warnings, &String.contains?(&1, "readonly.txt"))
    end

    test "saved buffers are no longer dirty", %{tmp_dir: dir} do
      path = Path.join(dir, "dirty.txt")
      File.write!(path, "original")

      buf = start_file_buffer(path)
      :ok = Server.insert_text(buf, " MODIFIED")
      assert Server.dirty?(buf)

      Buffer.save_all_dirty()

      refute Server.dirty?(buf)
    end
  end
end
