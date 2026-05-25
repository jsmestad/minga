defmodule MingaDired.CoreTest do
  use ExUnit.Case, async: true

  alias MingaDired.Core, as: Dired
  alias MingaDired.Entry

  @moduletag :tmp_dir

  describe "read_directory/2" do
    test "reads files and directories from a path", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "alpha.ex"), "")
      File.write!(Path.join(dir, "beta.txt"), "")
      File.mkdir_p!(Path.join(dir, "gamma"))

      assert {:ok, dired} = Dired.read_directory(dir)
      names = Enum.map(dired.entries, & &1.name)

      assert "gamma" in names
      assert "alpha.ex" in names
      assert "beta.txt" in names
    end

    test "entries are Entry structs", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "hello.txt"), "")

      assert {:ok, dired} = Dired.read_directory(dir)
      assert [%Entry{name: "hello.txt"}] = dired.entries
    end

    test "sorts directories first, then alphabetically", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "zebra.txt"), "")
      File.write!(Path.join(dir, "apple.txt"), "")
      File.mkdir_p!(Path.join(dir, "lib"))
      File.mkdir_p!(Path.join(dir, "app"))

      assert {:ok, dired} = Dired.read_directory(dir)
      names = Enum.map(dired.entries, & &1.name)

      assert names == ["app", "lib", "apple.txt", "zebra.txt"]
    end

    test "filters hidden files by default", %{tmp_dir: dir} do
      File.write!(Path.join(dir, ".hidden"), "")
      File.write!(Path.join(dir, "visible.txt"), "")

      assert {:ok, dired} = Dired.read_directory(dir)
      names = Enum.map(dired.entries, & &1.name)

      refute ".hidden" in names
      assert "visible.txt" in names
    end

    test "shows hidden files when requested", %{tmp_dir: dir} do
      File.write!(Path.join(dir, ".hidden"), "")
      File.write!(Path.join(dir, "visible.txt"), "")

      assert {:ok, dired} = Dired.read_directory(dir, show_hidden: true)
      names = Enum.map(dired.entries, & &1.name)

      assert ".hidden" in names
      assert "visible.txt" in names
    end

    test "detects directories", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "subdir"))
      File.write!(Path.join(dir, "file.txt"), "")

      assert {:ok, dired} = Dired.read_directory(dir)

      subdir = Enum.find(dired.entries, &(&1.name == "subdir"))
      file = Enum.find(dired.entries, &(&1.name == "file.txt"))

      assert subdir.dir?
      refute file.dir?
    end

    test "returns error for nonexistent path" do
      assert {:error, :enoent} = Dired.read_directory("/nonexistent/path/xyz")
    end

    test "sorts by size", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "small.txt"), "a")
      File.write!(Path.join(dir, "big.txt"), String.duplicate("x", 1000))

      assert {:ok, dired} = Dired.read_directory(dir, sort_by: :size)
      file_names = dired.entries |> Enum.reject(& &1.dir?) |> Enum.map(& &1.name)

      assert file_names == ["small.txt", "big.txt"]
    end

    test "sorts by extension", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "main.ex"), "")
      File.write!(Path.join(dir, "style.css"), "")
      File.write!(Path.join(dir, "readme.txt"), "")

      assert {:ok, dired} = Dired.read_directory(dir, sort_by: :extension)
      file_names = dired.entries |> Enum.reject(& &1.dir?) |> Enum.map(& &1.name)

      assert file_names == ["style.css", "main.ex", "readme.txt"]
    end
  end

  describe "format_entry/2" do
    test "appends / to directories" do
      entry = %Entry{
        name: "lib",
        dir?: true,
        symlink?: false,
        target: nil,
        executable?: false,
        size: 0,
        mtime: nil,
        mode: 0o755,
        path: "/tmp/lib"
      }

      assert Dired.format_entry(entry) == "lib/"
    end

    test "appends * to executables" do
      entry = %Entry{
        name: "run.sh",
        dir?: false,
        symlink?: false,
        target: nil,
        executable?: true,
        size: 0,
        mtime: nil,
        mode: 0o755,
        path: "/tmp/run.sh"
      }

      assert Dired.format_entry(entry) == "run.sh*"
    end

    test "shows symlink target" do
      entry = %Entry{
        name: "link",
        dir?: false,
        symlink?: true,
        target: "/usr/bin/thing",
        executable?: false,
        size: 0,
        mtime: nil,
        mode: 0o777,
        path: "/tmp/link"
      }

      assert Dired.format_entry(entry) == "link@ -> /usr/bin/thing"
    end

    test "plain file has no indicator" do
      entry = %Entry{
        name: "file.txt",
        dir?: false,
        symlink?: false,
        target: nil,
        executable?: false,
        size: 0,
        mtime: nil,
        mode: 0o644,
        path: "/tmp/file.txt"
      }

      assert Dired.format_entry(entry) == "file.txt"
    end

    test "includes details when show_details is true" do
      entry = %Entry{
        name: "file.txt",
        dir?: false,
        symlink?: false,
        target: nil,
        executable?: false,
        size: 512,
        mtime: ~N[2025-03-15 10:30:00],
        mode: 0o100644,
        path: "/tmp/file.txt"
      }

      result = Dired.format_entry(entry, true)

      assert result =~ "rw-"
      assert result =~ "512"
      assert result =~ "Mar"
      assert result =~ "file.txt"
    end
  end

  describe "format_listing/1" do
    test "produces one line per entry", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "")
      File.write!(Path.join(dir, "b.txt"), "")

      assert {:ok, dired} = Dired.read_directory(dir)
      listing = Dired.format_listing(dired)
      lines = String.split(listing, "\n", trim: true)

      assert length(lines) == 2
    end
  end

  describe "parse_listing/1" do
    test "extracts plain filenames" do
      text = "alpha.ex\nbeta.txt\n"
      assert Dired.parse_listing(text) == ["alpha.ex", "beta.txt"]
    end

    test "preserves directory indicator for mkdir detection" do
      assert Dired.parse_listing("lib/\ntest/\n") == ["lib/", "test/"]
    end

    test "strips executable indicator" do
      assert Dired.parse_listing("run.sh*\n") == ["run.sh"]
    end

    test "strips symlink target" do
      assert Dired.parse_listing("link@ -> /usr/bin/thing\n") == ["link"]
    end

    test "skips empty lines" do
      assert Dired.parse_listing("a.txt\n\n\nb.txt\n") == ["a.txt", "b.txt"]
    end

    test "strips detail prefix" do
      line = "-rw-r--r--    1234 Mar 15 10:30 file.txt"
      assert Dired.parse_listing(line) == ["file.txt"]
    end

    test "strips detail prefix with nil mtime placeholder" do
      line = "-rw-r--r--       0 --- -- --:-- broken.txt"
      assert Dired.parse_listing(line) == ["broken.txt"]
    end
  end

  describe "diff_operations/3" do
    test "detects no changes" do
      entries = [
        %Entry{name: "a.txt", path: "/d/a.txt"},
        %Entry{name: "b.txt", path: "/d/b.txt"}
      ]

      assert Dired.diff_operations(entries, ["a.txt", "b.txt"], "/d") == []
    end

    test "detects renames by position with absolute paths" do
      entries = [
        %Entry{name: "old.txt", path: "/d/old.txt"},
        %Entry{name: "keep.txt", path: "/d/keep.txt"}
      ]

      ops = Dired.diff_operations(entries, ["new.txt", "keep.txt"], "/d")
      assert {:rename, "/d/old.txt", "/d/new.txt"} in ops
    end

    test "detects deletions with absolute paths" do
      entries = [
        %Entry{name: "a.txt", path: "/d/a.txt"},
        %Entry{name: "b.txt", path: "/d/b.txt"}
      ]

      ops = Dired.diff_operations(entries, ["a.txt"], "/d")
      assert {:delete, "/d/b.txt"} in ops
    end

    test "detects file creation with absolute path" do
      entries = [%Entry{name: "a.txt", path: "/d/a.txt"}]
      ops = Dired.diff_operations(entries, ["a.txt", "new.txt"], "/d")

      assert {:create, "/d/new.txt"} in ops
    end

    test "detects directory creation with absolute path" do
      entries = [%Entry{name: "a.txt", path: "/d/a.txt"}]
      ops = Dired.diff_operations(entries, ["a.txt", "newdir/"], "/d")

      assert {:mkdir, "/d/newdir"} in ops
    end

    test "handles mixed operations with absolute paths" do
      entries = [
        %Entry{name: "old.txt", path: "/d/old.txt"},
        %Entry{name: "delete_me.txt", path: "/d/delete_me.txt"},
        %Entry{name: "keep.txt", path: "/d/keep.txt"}
      ]

      current = ["renamed.txt", "keep.txt", "brand_new.txt"]
      ops = Dired.diff_operations(entries, current, "/d")

      assert {:rename, "/d/old.txt", "/d/renamed.txt"} in ops
      assert {:delete, "/d/delete_me.txt"} in ops
      assert {:create, "/d/brand_new.txt"} in ops
    end

    test "all entries deleted produces delete ops for each" do
      entries = [
        %Entry{name: "a.txt", path: "/d/a.txt"},
        %Entry{name: "b.txt", path: "/d/b.txt"}
      ]

      ops = Dired.diff_operations(entries, [], "/d")
      assert length(ops) == 2
      assert {:delete, "/d/a.txt"} in ops
      assert {:delete, "/d/b.txt"} in ops
    end

    test "duplicate names in current list treats extra as create" do
      entries = [%Entry{name: "a.txt", path: "/d/a.txt"}]
      ops = Dired.diff_operations(entries, ["a.txt", "a.txt"], "/d")

      assert {:create, "/d/a.txt"} in ops
    end

    test "empty original and empty current produces no ops" do
      assert Dired.diff_operations([], [], "/d") == []
    end
  end

  describe "entry_at_line/2" do
    test "returns the entry at the given line index" do
      dired = %Dired{
        entries: [
          %Entry{name: "first", path: "/d/first"},
          %Entry{name: "second", path: "/d/second"}
        ]
      }

      assert Dired.entry_at_line(dired, 0).name == "first"
      assert Dired.entry_at_line(dired, 1).name == "second"
      assert Dired.entry_at_line(dired, 2) == nil
    end
  end

  describe "parent_directory/1" do
    test "returns the parent path" do
      assert Dired.parent_directory("/home/user/code") == "/home/user"
    end
  end

  describe "next_sort_key/1" do
    test "cycles through sort keys" do
      assert Dired.next_sort_key(:name) == :size
      assert Dired.next_sort_key(:size) == :date
      assert Dired.next_sort_key(:date) == :extension
      assert Dired.next_sort_key(:extension) == :name
    end
  end

  describe "round-trip: format then parse" do
    test "parse_listing recovers names from format_listing (dirs keep /)", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "hello.ex"), "")
      File.mkdir_p!(Path.join(dir, "subdir"))

      assert {:ok, dired} = Dired.read_directory(dir)
      listing = Dired.format_listing(dired)
      parsed = Dired.parse_listing(listing)

      expected = Enum.map(dired.entries, fn e -> if e.dir?, do: e.name <> "/", else: e.name end)
      assert parsed == expected
    end

    test "round-trips with detail columns", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "file.txt"), "some content")
      File.mkdir_p!(Path.join(dir, "mydir"))

      assert {:ok, dired} = Dired.read_directory(dir, show_details: true)
      listing = Dired.format_listing(dired)
      parsed = Dired.parse_listing(listing)

      expected = Enum.map(dired.entries, fn e -> if e.dir?, do: e.name <> "/", else: e.name end)
      assert parsed == expected
    end
  end
end
