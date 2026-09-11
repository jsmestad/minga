defmodule Minga.PlatformTest do
  use ExUnit.Case, async: true

  alias Minga.Platform.MacOSTrash

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

  describe "macOS Trash command" do
    test "passes the literal pathname through argv to a fixed AppleScriptObjC program" do
      path = "/tmp/apostrophe' quote\" backslash\\n snow-雪\nline"
      test_process = self()

      runner = fn command, args, opts ->
        send(test_process, {:command, command, args, opts})
        {"/Users/example/.Trash/result\n", 0}
      end

      assert :ok = MacOSTrash.trash(path, runner)

      assert_receive {:command, "osascript", ["-e", script, "--", ^path],
                      [stderr_to_stdout: true]}

      assert script =~ "on run argv"
      assert script =~ "fileURLWithPath:(item 1 of argv)"
      assert script =~ "trashItemAtURL:fileURL"
      refute script =~ path
    end

    test "returns the native command failure text" do
      runner = fn "osascript", _args, [stderr_to_stdout: true] ->
        {"  The selected entry could not be moved.\n", 1}
      end

      assert {:error, "The selected entry could not be moved."} =
               MacOSTrash.trash("/tmp/missing", runner)
    end

    test "returns an error when osascript cannot start" do
      runner = fn "osascript", _args, [stderr_to_stdout: true] ->
        raise ErlangError, original: :enoent
      end

      assert {:error, "osascript failed: " <> reason} = MacOSTrash.trash("/tmp/missing", runner)
      assert reason != ""
    end
  end

  if :os.type() == {:unix, :darwin} do
    describe "trash/1 (macOS production backend)" do
      @describetag :heavy
      @describetag :tmp_dir

      test "preserves literal filename bytes and leaves similar entries untouched", %{
        tmp_dir: dir
      } do
        filenames = [
          "apostrophe's",
          "double\"quote",
          "back\\slash",
          "literal\\nsequence",
          "unicode-雪-🙂",
          "line\nbreak"
        ]

        for filename <- filenames do
          selected = Path.join(dir, unique_filename(filename))
          similar = selected <> ".untouched"
          destination = trash_destination(selected)
          assert_missing(destination)
          register_cleanup([selected, similar, destination])

          File.write!(selected, "selected")
          File.write!(similar, "unrelated")

          assert :ok = Minga.Platform.System.trash(selected)
          assert_missing(selected)
          assert File.read!(destination) == "selected"
          assert File.read!(similar) == "unrelated"
        end
      end

      test "moves a file symlink without changing its target or unrelated entries", %{
        tmp_dir: dir
      } do
        target = Path.join(dir, unique_filename("file-target"))
        link = Path.join(dir, unique_filename("file-link"))
        unrelated = Path.join(dir, unique_filename("unrelated"))
        destination = trash_destination(link)
        assert_missing(destination)
        register_cleanup([target, link, unrelated, destination])

        File.write!(target, "target content")
        File.write!(unrelated, "unrelated content")
        File.ln_s!(target, link)

        assert :ok = Minga.Platform.System.trash(link)
        assert_missing(link)
        assert File.read!(target) == "target content"
        assert File.read!(unrelated) == "unrelated content"
        assert {:ok, %File.Stat{type: :symlink}} = File.lstat(destination)
        assert File.read_link!(destination) == target
      end

      test "moves a directory symlink without changing its target contents", %{tmp_dir: dir} do
        target = Path.join(dir, unique_filename("directory-target"))
        target_child = Path.join(target, "child.txt")
        link = Path.join(dir, unique_filename("directory-link"))
        unrelated = Path.join(dir, unique_filename("unrelated"))
        destination = trash_destination(link)
        assert_missing(destination)
        register_cleanup([target, link, unrelated, destination])

        File.mkdir_p!(target)
        File.write!(target_child, "target content")
        File.write!(unrelated, "unrelated content")
        File.ln_s!(target, link)

        assert :ok = Minga.Platform.System.trash(link)
        assert_missing(link)
        assert File.read!(target_child) == "target content"
        assert File.read!(unrelated) == "unrelated content"
        assert {:ok, %File.Stat{type: :symlink}} = File.lstat(destination)
        assert File.read_link!(destination) == target
      end

      test "moves a dangling symlink without creating or changing its absent target", %{
        tmp_dir: dir
      } do
        missing_target = Path.join(dir, unique_filename("missing-target"))
        link = Path.join(dir, unique_filename("dangling-link"))
        unrelated = Path.join(dir, unique_filename("unrelated"))
        destination = trash_destination(link)
        assert_missing(destination)
        register_cleanup([missing_target, link, unrelated, destination])

        File.write!(unrelated, "unrelated content")
        File.ln_s!(missing_target, link)

        assert :ok = Minga.Platform.System.trash(link)
        assert_missing(link)
        assert_missing(missing_target)
        assert File.read!(unrelated) == "unrelated content"
        assert {:ok, %File.Stat{type: :symlink}} = File.lstat(destination)
        assert File.read_link!(destination) == missing_target
      end

      test "reports a native error when the selected entry is missing", %{tmp_dir: dir} do
        missing = Path.join(dir, unique_filename("missing"))

        assert {:error, reason} = Minga.Platform.System.trash(missing)
        assert reason != ""
        assert_missing(missing)
      end
    end

    defp unique_filename(fragment) do
      "minga-3312-#{System.os_time(:nanosecond)}-#{fragment}-#{System.unique_integer([:positive, :monotonic])}.txt"
    end

    defp trash_destination(path) do
      System.user_home!()
      |> Path.join(".Trash")
      |> Path.join(Path.basename(path))
    end

    defp register_cleanup(paths) do
      on_exit(fn -> Enum.each(paths, &remove_entry/1) end)
    end

    defp remove_entry(path) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> File.rm_rf!(path)
        {:ok, _stat} -> File.rm!(path)
        {:error, :enoent} -> :ok
        {:error, reason} -> raise File.Error, reason: reason, action: "clean up", path: path
      end
    end

    defp assert_missing(path) do
      assert {:error, :enoent} = File.lstat(path)
    end
  end
end
