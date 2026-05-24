defmodule MingaAgent.Tools.MemoryWriteTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Memory
  alias MingaAgent.Tools.MemoryWrite

  @moduletag :tmp_dir

  describe "execute/2" do
    test "rejects empty string", %{tmp_dir: dir} do
      assert {:error, "Memory text cannot be empty"} = MemoryWrite.execute("", dir)
    end

    test "rejects whitespace-only input", %{tmp_dir: dir} do
      assert {:error, "Memory text cannot be empty"} = MemoryWrite.execute("   \n\t  ", dir)
    end

    test "saves valid text and confirms it in the memory file", %{tmp_dir: dir} do
      assert {:ok, "Saved to memory: user prefers tabs"} =
               MemoryWrite.execute("user prefers tabs", dir)

      content = Memory.read(dir)
      assert content =~ "user prefers tabs"
    end

    test "wraps error when the underlying append fails", %{tmp_dir: dir} do
      readonly_dir = Path.join(dir, "locked")
      File.mkdir_p!(Path.join(readonly_dir, "minga"))
      File.chmod!(Path.join(readonly_dir, "minga"), 0o444)

      assert {:error, "Failed to save memory: " <> _reason} =
               MemoryWrite.execute("should fail", readonly_dir)

      File.chmod!(Path.join(readonly_dir, "minga"), 0o755)
    end
  end
end
