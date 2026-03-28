defmodule Minga.PlatformTest do
  use ExUnit.Case, async: true

  describe "permanent_delete/1" do
    @tag :tmp_dir
    test "deletes a file", %{tmp_dir: dir} do
      path = Path.join(dir, "delete_me.txt")
      File.write!(path, "content")
      assert File.exists?(path)

      assert :ok = Minga.Platform.permanent_delete(path)
      refute File.exists?(path)
    end

    @tag :tmp_dir
    test "deletes a directory recursively", %{tmp_dir: dir} do
      sub = Path.join(dir, "subdir")
      File.mkdir_p!(sub)
      File.write!(Path.join(sub, "child.txt"), "content")
      assert File.exists?(sub)

      assert :ok = Minga.Platform.permanent_delete(sub)
      refute File.exists?(sub)
    end

    test "returns error for non-existent file" do
      result = Minga.Platform.permanent_delete("/tmp/does_not_exist_#{System.unique_integer()}")
      assert {:error, _} = result
    end
  end

  describe "trash/1 (stub)" do
    test "stub returns :ok by default" do
      assert :ok = Minga.Platform.trash("/tmp/fake_path")
    end

    test "stub returns configured error" do
      Minga.Platform.Stub.set_trash_result({:error, "no trash support"})
      assert {:error, "no trash support"} = Minga.Platform.trash("/tmp/fake_path")
    after
      # Clean up process dictionary
      Minga.Platform.Stub.set_trash_result(:ok)
    end
  end
end
