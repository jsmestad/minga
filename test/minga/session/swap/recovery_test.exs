defmodule Minga.Session.Swap.RecoveryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Minga.Session.Swap
  alias Minga.Session.Swap.Recovery

  @moduletag :tmp_dir

  defp write_swap_file(tmp_dir, file_path, content, opts \\ []) do
    os_pid = Keyword.get(opts, :os_pid, 99_999)
    mtime = Keyword.get(opts, :mtime, System.os_time(:second))

    header = "path=#{file_path}\nos_pid=#{os_pid}\nmtime=#{mtime}"
    header_len = byte_size(header)
    data = <<"MINGA_SWAP_V1\n", header_len::32-big, header::binary, content::binary>>

    hash = :crypto.hash(:sha256, file_path) |> Base.hex_encode32(case: :lower, padding: false)
    swap_path = Path.join(tmp_dir, "#{hash}.#{os_pid}.swap")
    File.write!(swap_path, data)
    swap_path
  end

  defp scan_opts(tmp_dir, pid_alive? \\ fn _ -> false end) do
    [swap_dir: tmp_dir, pid_alive?: pid_alive?]
  end

  describe "scan/1" do
    test "returns empty list when swap directory doesn't exist" do
      assert Recovery.scan(swap_dir: "/nonexistent/path") == []
    end

    test "returns empty list when swap directory is empty", %{tmp_dir: tmp_dir} do
      assert Recovery.scan(scan_opts(tmp_dir)) == []
    end

    test "finds recoverable swap files for existing original files", %{tmp_dir: tmp_dir} do
      original = Path.join(tmp_dir, "original.ex")
      File.write!(original, "original content")

      swap_path = write_swap_file(tmp_dir, original, "modified content")

      results = Recovery.scan(scan_opts(tmp_dir))
      assert Enum.count(results) == 1
      assert hd(results).path == original
      assert hd(results).swap_path == swap_path
    end

    test "keeps a swap whose original file was deleted: it is the only copy of that text", %{
      tmp_dir: tmp_dir
    } do
      swap_path = write_swap_file(tmp_dir, "/nonexistent/deleted.ex", "content")

      assert [%{path: "/nonexistent/deleted.ex", swap_path: ^swap_path}] =
               Recovery.scan(scan_opts(tmp_dir))

      assert File.exists?(swap_path)
    end

    test "leaves an unparseable swap alone while the editor named in its file name runs", %{
      tmp_dir: tmp_dir
    } do
      # A running editor of another version may write a format this build cannot parse.
      newer_format = Path.join(tmp_dir, "abc123.4242.swap")
      File.write!(newer_format, "MINGA_SWAP_V9\nsomething else")

      assert Recovery.scan(scan_opts(tmp_dir, fn pid -> pid == 4242 end)) == []
      assert File.exists?(newer_format)

      log = capture_log(fn -> assert Recovery.scan(scan_opts(tmp_dir)) == [] end)

      refute File.exists?(newer_format)
      assert log =~ "Removed a swap file that cannot be parsed"
    end

    test "skips swap files owned by a still-running process", %{tmp_dir: tmp_dir} do
      original = Path.join(tmp_dir, "active.ex")
      File.write!(original, "content")

      alive_pid = 12_345
      write_swap_file(tmp_dir, original, "modified", os_pid: alive_pid)

      # PID is alive: swap file should be skipped
      results = Recovery.scan(scan_opts(tmp_dir, fn pid -> pid == alive_pid end))
      assert results == []
    end

    test "skips and cleans up corrupt swap files", %{tmp_dir: tmp_dir} do
      corrupt_path = Path.join(tmp_dir, "corrupt.swap")
      File.write!(corrupt_path, "garbage")

      results = Recovery.scan(scan_opts(tmp_dir))
      assert results == []
      refute File.exists?(corrupt_path)
    end

    test "ignores non-.swap files in the directory", %{tmp_dir: tmp_dir} do
      other_file = Path.join(tmp_dir, "random.txt")
      File.write!(other_file, "not a swap file")

      results = Recovery.scan(scan_opts(tmp_dir))
      assert results == []
      # The file should NOT be deleted
      assert File.exists?(other_file)
    end

    test "removes only recognized temporary files whose owner is dead", %{tmp_dir: tmp_dir} do
      dead_pid = 99_991
      live_pid = 99_992

      assert {:ok, dead_temp} =
               Swap.prepare("/tmp/dead-temp.ex", "dead", swap_dir: tmp_dir, os_pid: dead_pid)

      assert {:ok, live_temp} =
               Swap.prepare("/tmp/live-temp.ex", "live", swap_dir: tmp_dir, os_pid: live_pid)

      arbitrary_temp = Path.join(tmp_dir, "notes.tmp")
      similar_temp = Path.join(tmp_dir, "not-a-swap.#{dead_pid}.swap.1.2.tmp")
      File.write!(arbitrary_temp, "leave me")
      File.write!(similar_temp, "leave me too")

      pid_alive? = fn os_pid -> os_pid == live_pid end
      assert Recovery.scan(scan_opts(tmp_dir, pid_alive?)) == []

      refute File.exists?(dead_temp.temporary_path)
      assert File.exists?(live_temp.temporary_path)
      assert File.exists?(arbitrary_temp)
      assert File.exists?(similar_temp)
    end

    test "logs failure to remove a recognized orphaned temporary file", %{tmp_dir: tmp_dir} do
      os_pid = 99_993
      target = Swap.swap_path("/tmp/removal-failure.ex", swap_dir: tmp_dir, os_pid: os_pid)
      temporary_path = "#{target}.1.123.tmp"
      File.mkdir_p!(temporary_path)
      assert {:error, reason} = File.rm(temporary_path)

      log =
        capture_log(fn ->
          assert Recovery.scan(scan_opts(tmp_dir, fn _pid -> false end)) == []
        end)

      assert log =~ "Failed to remove orphaned swap temporary file"
      assert log =~ temporary_path
      assert log =~ inspect(reason)
      assert File.dir?(temporary_path)
    end

    test "finds multiple recoverable swap files", %{tmp_dir: tmp_dir} do
      for i <- 1..3 do
        original = Path.join(tmp_dir, "file#{i}.ex")
        File.write!(original, "content #{i}")
        write_swap_file(tmp_dir, original, "modified #{i}", os_pid: 99_990 + i)
      end

      results = Recovery.scan(scan_opts(tmp_dir))
      assert Enum.count(results) == 3
    end
  end

  describe "recover/1" do
    test "returns file path and content, deletes swap file", %{tmp_dir: tmp_dir} do
      original = Path.join(tmp_dir, "recover_me.ex")
      File.write!(original, "original")

      swap_path = write_swap_file(tmp_dir, original, "unsaved changes")
      assert File.exists?(swap_path)

      assert {:ok, ^original, "unsaved changes"} = Recovery.recover(swap_path)
      refute File.exists?(swap_path)
    end

    test "returns error for corrupt swap file", %{tmp_dir: tmp_dir} do
      corrupt_path = Path.join(tmp_dir, "bad.swap")
      File.write!(corrupt_path, "not valid")

      assert {:error, :invalid_format} = Recovery.recover(corrupt_path)
    end
  end

  describe "discard/1" do
    test "deletes the swap file", %{tmp_dir: tmp_dir} do
      original = Path.join(tmp_dir, "discard_me.ex")
      swap_path = write_swap_file(tmp_dir, original, "content")
      assert File.exists?(swap_path)

      :ok = Recovery.discard(swap_path)
      refute File.exists?(swap_path)
    end
  end

  describe "scan/1 scope" do
    setup %{tmp_dir: tmp_dir} do
      swap_dir = Path.join(tmp_dir, "swap")
      File.mkdir_p!(swap_dir)

      [alpha, beta] =
        for name <- ["alpha", "beta"] do
          root = Path.join(tmp_dir, name)
          File.mkdir_p!(Path.join(root, "lib"))
          File.write!(Path.join(root, "mix.exs"), "")
          file = Path.join(root, "lib/#{name}.ex")
          File.write!(file, "saved #{name}")
          write_swap_file(swap_dir, file, "unsaved #{name}")
          %{root: root, file: file}
        end

      %{swap_dir: swap_dir, alpha: alpha, beta: beta}
    end

    test "a project scope returns only that project's swaps and leaves the others on disk", ctx do
      opts = scan_opts(ctx.swap_dir) ++ [scope: {:project, ctx.alpha.root}]

      assert [%{path: path}] = Recovery.scan(opts)
      assert path == ctx.alpha.file

      # Project beta's text was not recovered into alpha, and it is still waiting.
      assert [%{path: beta_path}] =
               Recovery.scan(scan_opts(ctx.swap_dir) ++ [scope: {:project, ctx.beta.root}])

      assert beta_path == ctx.beta.file
    end

    test "a file scope returns the swap of that one file", ctx do
      opts = scan_opts(ctx.swap_dir) ++ [scope: {:file, ctx.beta.file}]

      assert [%{path: path}] = Recovery.scan(opts)
      assert path == ctx.beta.file
      assert Recovery.scan(scan_opts(ctx.swap_dir) ++ [scope: {:file, "/no/such/file.ex"}]) == []
    end

    test "a project opened through a symlink finds the swaps of its files", ctx do
      link = Path.join(Path.dirname(ctx.alpha.root), "alpha-link")
      File.ln_s!(ctx.alpha.root, link)

      assert [%{path: path}] =
               Recovery.scan(scan_opts(ctx.swap_dir) ++ [scope: {:project, link}])

      assert path == ctx.alpha.file
    end

    test "a scoped scan removes no swap that holds unsaved text or that it cannot parse", ctx do
      missing = Path.join(ctx.alpha.root, "lib/moved_away.ex")
      alpha_swap = write_swap_file(ctx.swap_dir, missing, "unsaved text of a missing file")
      unparseable = Path.join(ctx.swap_dir, "unparseable.swap")
      File.write!(unparseable, "garbage")

      beta = Recovery.scan(scan_opts(ctx.swap_dir) ++ [scope: {:project, ctx.beta.root}])

      assert Enum.map(beta, & &1.path) == [ctx.beta.file]
      assert File.exists?(alpha_swap)
      assert File.exists?(unparseable)

      # Opening alpha itself returns the text of the missing file for recovery.
      alpha = Recovery.scan(scan_opts(ctx.swap_dir) ++ [scope: {:project, ctx.alpha.root}])

      assert alpha |> Enum.map(& &1.path) |> Enum.sort() == Enum.sort([ctx.alpha.file, missing])
      assert File.exists?(alpha_swap)
      assert File.exists?(unparseable)
    end

    test "a missing file under a symlinked project root is still in that project's scope", ctx do
      link = Path.join(Path.dirname(ctx.alpha.root), "alpha-link")
      File.ln_s!(ctx.alpha.root, link)
      missing = Path.join(link, "lib/new_dir/never_saved.ex")
      write_swap_file(ctx.swap_dir, missing, "unsaved text")

      paths =
        (scan_opts(ctx.swap_dir) ++ [scope: {:project, ctx.alpha.root}])
        |> Recovery.scan()
        |> Enum.map(& &1.path)

      assert missing in paths
    end

    test "a files scope returns the swaps of the named files", ctx do
      opts = scan_opts(ctx.swap_dir) ++ [scope: {:files, [ctx.beta.file, "/no/such/file.ex"]}]

      assert [%{path: path}] = Recovery.scan(opts)
      assert path == ctx.beta.file
      assert Recovery.scan(scan_opts(ctx.swap_dir) ++ [scope: {:files, []}]) == []
    end

    test "an any scope returns what one of its scopes returns", ctx do
      scope = {:any, [{:project, ctx.alpha.root}, {:files, [ctx.beta.file]}]}

      paths =
        (scan_opts(ctx.swap_dir) ++ [scope: scope])
        |> Recovery.scan()
        |> Enum.map(& &1.path)
        |> Enum.sort()

      assert paths == Enum.sort([ctx.alpha.file, ctx.beta.file])
      assert Recovery.scan(scan_opts(ctx.swap_dir) ++ [scope: {:any, []}]) == []
    end

    test "the default scope returns every recoverable swap", ctx do
      paths = ctx.swap_dir |> scan_opts() |> Recovery.scan() |> Enum.map(& &1.path) |> Enum.sort()

      assert paths == Enum.sort([ctx.alpha.file, ctx.beta.file])
    end
  end

  describe "the lifetime of a swap file" do
    test "a swap whose text the file already holds is removed: nothing is unsaved", %{
      tmp_dir: tmp_dir
    } do
      original = Path.join(tmp_dir, "saved.ex")
      File.write!(original, "the same text")
      swap_path = write_swap_file(tmp_dir, original, "the same text")

      assert Recovery.scan(scan_opts(tmp_dir)) == []
      refute File.exists?(swap_path)
    end

    test "a swap whose file is gone stays recoverable", %{tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "deleted.ex")
      swap_path = write_swap_file(tmp_dir, missing, "unsaved text")

      assert [%{path: ^missing, swap_path: ^swap_path}] = Recovery.scan(scan_opts(tmp_dir))
      assert File.exists?(swap_path)
    end

    test "a swap that cannot be read right now is left alone", %{tmp_dir: tmp_dir} do
      # A directory with a swap file's name: reading it fails with :eisdir, not a format error.
      unreadable = Path.join(tmp_dir, "abc123.99999.swap")
      File.mkdir_p!(unreadable)

      assert Recovery.scan(scan_opts(tmp_dir)) == []
      assert File.dir?(unreadable)
    end

    test "a file that cannot be read keeps its swap recoverable", %{tmp_dir: tmp_dir} do
      # A directory stands where the file was, so reading it fails with :eisdir, not :enoent.
      original = Path.join(tmp_dir, "now_a_directory.ex")
      File.mkdir_p!(original)
      swap_path = write_swap_file(tmp_dir, original, "unsaved text")

      assert [%{path: ^original, swap_path: ^swap_path}] = Recovery.scan(scan_opts(tmp_dir))
      assert File.exists?(swap_path)
    end

    test "an entry says whether its file was written after the swap", %{tmp_dir: tmp_dir} do
      now = System.os_time(:second)
      untouched = Path.join(tmp_dir, "untouched.ex")
      saved_later = Path.join(tmp_dir, "saved_later.ex")
      gone = Path.join(tmp_dir, "gone.ex")

      for file <- [untouched, saved_later] do
        File.write!(file, "saved text")
        File.touch!(file, now - 100)
      end

      for file <- [untouched, saved_later, gone],
          do: write_swap_file(tmp_dir, file, "unsaved text", mtime: now - 50)

      # Another editor run, or another tool, wrote the file after the crash.
      File.touch!(saved_later, now)

      changed =
        tmp_dir |> scan_opts() |> Recovery.scan() |> Map.new(&{&1.path, &1.changed_since?})

      assert changed == %{untouched => false, saved_later => true, gone => false}
    end

    test "an old swap with different text is never removed for its age", %{tmp_dir: tmp_dir} do
      original = Path.join(tmp_dir, "old.ex")
      File.write!(original, "saved text")
      swap_path = write_swap_file(tmp_dir, original, "unsaved text", mtime: 1)

      assert [%{swap_path: ^swap_path, swap_mtime: 1}] = Recovery.scan(scan_opts(tmp_dir))
      assert File.exists?(swap_path)
    end

    test "a swap owned by a running editor is left alone even when its file is gone", %{
      tmp_dir: tmp_dir
    } do
      swap_path = write_swap_file(tmp_dir, Path.join(tmp_dir, "gone.ex"), "text", os_pid: 4242)

      assert Recovery.scan(scan_opts(tmp_dir, fn pid -> pid == 4242 end)) == []
      assert File.exists?(swap_path)
    end
  end

  describe "recoverable_projects/1" do
    test "counts waiting files per project and removes nothing", %{tmp_dir: tmp_dir} do
      swap_dir = Path.join(tmp_dir, "swap")
      File.mkdir_p!(swap_dir)
      root = Path.join(tmp_dir, "project")
      File.mkdir_p!(Path.join(root, "lib"))
      File.write!(Path.join(root, "mix.exs"), "")

      for name <- ["one", "two"] do
        file = Path.join(root, "lib/#{name}.ex")
        File.write!(file, "saved")
        write_swap_file(swap_dir, file, "unsaved #{name}")
      end

      # Already saved, and owned by a running editor: neither is waiting.
      saved = Path.join(root, "lib/saved.ex")
      File.write!(saved, "same")
      saved_swap = write_swap_file(swap_dir, saved, "same")
      owned = Path.join(root, "lib/owned.ex")
      File.write!(owned, "saved")
      write_swap_file(swap_dir, owned, "unsaved", os_pid: 4242)

      {:ok, canonical_root} = Minga.Project.Root.canonical_path(root)
      opts = scan_opts(swap_dir, fn pid -> pid == 4242 end)

      assert Recovery.recoverable_projects(opts) == [%{root: canonical_root, files: 2}]
      assert Minga.Session.recoverable_projects(opts) == [%{root: canonical_root, files: 2}]
      assert File.exists?(saved_swap)
    end

    test "counts a file under the deepest known root, and outside every root under nil", %{
      tmp_dir: tmp_dir
    } do
      swap_dir = Path.join(tmp_dir, "swap")
      File.mkdir_p!(swap_dir)
      outer = Path.join(tmp_dir, "outer")
      nested = Path.join(outer, "tools/nested")
      loose = Path.join(tmp_dir, "loose")
      Enum.each([nested, loose], &File.mkdir_p!/1)
      # A marker in the nested directory would make it its own project without `roots:`.
      File.write!(Path.join(nested, "mix.exs"), "")

      for file <- [Path.join(outer, "a.ex"), Path.join(nested, "b.ex"), Path.join(loose, "c.ex")] do
        File.write!(file, "saved")
        write_swap_file(swap_dir, file, "unsaved")
      end

      {:ok, outer_root} = Minga.Project.Root.canonical_path(outer)
      {:ok, nested_root} = Minga.Project.Root.canonical_path(nested)

      # Only the outer project is known: the nested file belongs to it, as a scan scoped to the outer root finds it.
      assert Recovery.recoverable_projects(scan_opts(swap_dir) ++ [roots: [outer]]) == [
               %{root: outer_root, files: 2},
               %{root: nil, files: 1}
             ]

      # Both are known: the nested file counts under the deepest root that contains it.
      assert Recovery.recoverable_projects(scan_opts(swap_dir) ++ [roots: [outer, nested]]) == [
               %{root: outer_root, files: 1},
               %{root: nested_root, files: 1},
               %{root: nil, files: 1}
             ]
    end

    test "outside: leaves out what a scan with that scope returns", %{tmp_dir: tmp_dir} do
      swap_dir = Path.join(tmp_dir, "swap")
      File.mkdir_p!(swap_dir)

      [opened, other] =
        for name <- ["opened", "other"] do
          root = Path.join(tmp_dir, name)
          File.mkdir_p!(root)
          File.write!(Path.join(root, "mix.exs"), "")
          file = Path.join(root, "notes.txt")
          File.write!(file, "saved")
          write_swap_file(swap_dir, file, "unsaved #{name}")
          root
        end

      {:ok, other_root} = Minga.Project.Root.canonical_path(other)
      opts = scan_opts(swap_dir) ++ [outside: {:project, opened}]

      assert Recovery.recoverable_projects(opts) == [%{root: other_root, files: 1}]
    end

    test "is empty when the swap directory does not exist" do
      assert Recovery.recoverable_projects(swap_dir: "/nonexistent/path") == []
    end
  end

  describe "read/1" do
    test "returns the file path and the text, and leaves the swap file on disk", %{
      tmp_dir: tmp_dir
    } do
      original = Path.join(tmp_dir, "notes.txt")
      swap_path = write_swap_file(tmp_dir, original, "unsaved text")

      assert Recovery.read(swap_path) == {:ok, original, "unsaved text"}
      assert Minga.Session.read_swap_file(swap_path) == {:ok, original, "unsaved text"}
      assert File.exists?(swap_path)
    end

    test "reports a swap that cannot be parsed", %{tmp_dir: tmp_dir} do
      swap_path = Path.join(tmp_dir, "broken.swap")
      File.write!(swap_path, "garbage")

      assert Recovery.read(swap_path) == {:error, :invalid_format}
      assert File.exists?(swap_path)
    end
  end

  describe "waiting/1" do
    setup %{tmp_dir: tmp_dir} do
      swap_dir = Path.join(tmp_dir, "swap")
      File.mkdir_p!(swap_dir)
      root = Path.join(tmp_dir, "project")
      File.mkdir_p!(Path.join(root, "lib"))
      File.write!(Path.join(root, "mix.exs"), "")
      {:ok, canonical_root} = Minga.Project.Root.canonical_path(root)
      %{swap_dir: swap_dir, root: root, canonical_root: canonical_root}
    end

    test "says where each text belongs, when it was written and how it differs", ctx do
      now = System.os_time(:second)
      edited = Path.join(ctx.root, "lib/edited.ex")
      File.write!(edited, "one\ntwo\nthree\n")
      File.touch!(edited, now - 600)
      write_swap_file(ctx.swap_dir, edited, "one\nTWO\nthree\nfour\n", mtime: now - 300)

      assert [entry] = Recovery.waiting(scan_opts(ctx.swap_dir))

      assert entry.path == edited
      assert entry.project == ctx.canonical_root
      assert entry.swap_mtime == now - 300
      assert entry.file_exists?
      refute entry.changed_since?
      # "one", "TWO", "three", "four" and the empty piece after the last newline.
      assert entry.lines == 5
      # "two" became "TWO" and "four" was added: two lines differ.
      assert entry.changed_lines == 2
    end

    test "lists text that no start recovers by itself, newest first, and removes nothing", ctx do
      now = System.os_time(:second)
      gone = Path.join(ctx.root, "lib/gone.ex")
      held_back = Path.join(ctx.root, "lib/saved_later.ex")
      loose = Path.join(Path.dirname(ctx.root), "loose.txt")
      File.write!(held_back, "saved later")
      File.write!(loose, "saved")

      gone_swap = write_swap_file(ctx.swap_dir, gone, "typed for an hour", mtime: now - 30)
      held_swap = write_swap_file(ctx.swap_dir, held_back, "older text", mtime: now - 3_600)
      loose_swap = write_swap_file(ctx.swap_dir, loose, "unsaved", mtime: now - 60)
      File.touch!(loose, now - 120)
      # Owned by a running editor: not waiting.
      owned = Path.join(ctx.root, "lib/owned.ex")
      File.write!(owned, "saved")
      write_swap_file(ctx.swap_dir, owned, "unsaved", os_pid: 4242)

      waiting = Recovery.waiting(scan_opts(ctx.swap_dir, fn pid -> pid == 4242 end))

      assert Enum.map(waiting, & &1.path) == [gone, loose, held_back]

      assert [
               %{file_exists?: false, changed_lines: nil, lines: 1, project: project},
               %{file_exists?: true, project: other_project, changed_since?: false},
               %{file_exists?: true, changed_since?: true}
             ] = waiting

      assert project == ctx.canonical_root
      # The loose file is outside the project. What is above it depends on where the test runs.
      refute other_project == ctx.canonical_root

      assert Minga.Session.waiting_unsaved_text(
               scan_opts(ctx.swap_dir, fn pid -> pid == 4242 end)
             ) == waiting

      for swap <- [gone_swap, held_swap, loose_swap], do: assert(File.exists?(swap))
    end

    test "is empty when nothing waits or the swap directory does not exist", ctx do
      assert Recovery.waiting(scan_opts(ctx.swap_dir)) == []
      assert Recovery.waiting(swap_dir: "/nonexistent/path") == []
    end
  end
end
