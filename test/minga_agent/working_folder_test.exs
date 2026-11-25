defmodule MingaAgent.WorkingFolderTest do
  use ExUnit.Case, async: true

  alias MingaAgent.WorkingFolder

  @moduletag :tmp_dir

  @no_folder "Minga has no folder to work in. Open a file or a folder."

  describe "folder/1" do
    test "a plain folder is the session's folder, named by its canonical path", %{tmp_dir: dir} do
      real = Path.join(dir, "real")
      link = Path.join(dir, "link")
      File.mkdir_p!(real)
      File.ln_s!(real, link)
      {:ok, canonical} = Minga.Project.Root.canonical_path(real)

      assert WorkingFolder.folder(real) == {:folder, canonical}
      assert WorkingFolder.folder(link) == {:folder, canonical}
    end

    test "nothing opened, a relative path, a missing path and a file all leave the session without a folder",
         %{tmp_dir: dir} do
      file = Path.join(dir, "notes.txt")
      File.write!(file, "")

      for candidate <- [nil, "relative/folder", Path.join(dir, "missing"), file] do
        assert WorkingFolder.folder(candidate) == {:unavailable, :none}
      end
    end

    test "the home directory, the filesystem root and a link to either are too broad",
         %{tmp_dir: dir} do
      {:ok, home} = Minga.Project.Root.canonical_path(Path.expand("~"))
      home_link = Path.join(dir, "home")
      root_link = Path.join(dir, "root")
      File.ln_s!(home, home_link)
      File.ln_s!("/", root_link)

      assert WorkingFolder.folder(home) == {:unavailable, {:too_broad, home}}
      assert WorkingFolder.folder(home_link) == {:unavailable, {:too_broad, home}}
      assert WorkingFolder.folder("/") == {:unavailable, {:too_broad, "/"}}
      assert WorkingFolder.folder(root_link) == {:unavailable, {:too_broad, "/"}}
    end
  end

  describe "for_file/1" do
    test "a file's folder is the session's folder", %{tmp_dir: dir} do
      {:ok, canonical} = Minga.Project.Root.canonical_path(dir)

      assert WorkingFolder.for_file(Path.join(dir, "notes.txt")) == {:folder, canonical}
      assert WorkingFolder.for_file(nil) == {:unavailable, :none}
    end

    test "a file directly in the home directory or the filesystem root gives no folder" do
      {:ok, home} = Minga.Project.Root.canonical_path(Path.expand("~"))

      assert WorkingFolder.for_file(Path.join(home, "notes.txt")) ==
               {:unavailable, {:too_broad, home}}

      assert WorkingFolder.for_file("/notes.txt") == {:unavailable, {:too_broad, "/"}}
    end
  end

  describe "first_available/1" do
    test "the first candidate with a folder wins, and a too-broad candidate explains a refusal",
         %{tmp_dir: dir} do
      folder = WorkingFolder.folder(dir)
      none = {:unavailable, :none}
      broad = {:unavailable, {:too_broad, "/"}}

      assert WorkingFolder.first_available([none, folder]) == folder
      assert WorkingFolder.first_available([broad, folder]) == folder
      assert WorkingFolder.first_available([none, broad]) == broad
      assert WorkingFolder.first_available([none, none]) == none
    end
  end

  describe "what the person and the model are told" do
    test "a project says nothing and refuses nothing" do
      project = WorkingFolder.project("/work/app")

      assert WorkingFolder.root(project) == "/work/app"
      assert WorkingFolder.available?(project)
      assert WorkingFolder.notice(project) == nil
      assert WorkingFolder.refusal(project) == nil
    end

    test "a plain folder is named once and refuses nothing", %{tmp_dir: dir} do
      {:folder, root} = folder = WorkingFolder.folder(dir)

      assert WorkingFolder.notice(folder) ==
               "Minga is working in #{Minga.Project.collapse_home(root)}. No project was detected there."

      assert WorkingFolder.refusal(folder) == nil
    end

    test "no folder gives the same single line to the conversation and to every tool" do
      none = {:unavailable, :none}

      assert WorkingFolder.root(none) == nil
      refute WorkingFolder.available?(none)
      assert WorkingFolder.refusal(none) == @no_folder
      assert WorkingFolder.notice(none) == @no_folder
    end

    test "a too-broad folder is named, with the way out" do
      {:ok, home} = Minga.Project.Root.canonical_path(Path.expand("~"))
      line = WorkingFolder.refusal({:unavailable, {:too_broad, home}})

      assert line ==
               "Minga has no folder to work in: ~ is too broad. Open a folder inside it, or move the file into a folder."

      assert WorkingFolder.notice({:unavailable, {:too_broad, home}}) == line
      refute line =~ "\n"
    end
  end

  test "the private root of a session without a folder is never a project" do
    assert WorkingFolder.project(WorkingFolder.placeholder_root()) == {:unavailable, :none}
  end

  describe "runs_without_folder?/1" do
    test "only Minga's own tools known to stay away from the user's files run without a folder" do
      for name <-
            ~w(ask_user todo_read todo_write describe_runtime describe_tools memory_read fetch_url) do
        assert WorkingFolder.runs_without_folder?(%{name: name, source: :builtin})
        assert WorkingFolder.runs_without_folder?(%{name: name, source: {:bundle, :memory_tools}})
      end

      assert WorkingFolder.runs_without_folder?(%{name: "produce_rewrite", source: :config})

      for name <-
            ~w(read_file write_file edit_file find grep list_directory shell git_status definition subagent) do
        refute WorkingFolder.runs_without_folder?(%{name: name, source: :builtin})
      end
    end

    test "everything else is refused: MCP bridges, config and extension tools, even under a listed name" do
      for name <- ~w(list_mcp_tools call_mcp_tool my_config_tool ask_user fetch_url) do
        refute WorkingFolder.runs_without_folder?(%{name: name, source: :config})
        refute WorkingFolder.runs_without_folder?(%{name: name, source: {:extension, :anything}})
      end
    end
  end

  describe "another spelling of a broad folder" do
    test "a hard path to the same directory as the home directory is as broad as its usual name",
         %{tmp_dir: dir} do
      # A second link resolves to the home directory itself; the comparison is by directory, not by name.
      {:ok, home} = Minga.Project.Root.canonical_path(Path.expand("~"))
      link = Path.join(dir, "deep/link")
      File.mkdir_p!(Path.dirname(link))
      File.ln_s!(home, link)

      assert {:unavailable, {:too_broad, _path}} =
               WorkingFolder.for_file(Path.join(link, "notes.txt"))
    end

    @tag :macos_firmlink
    test "the data-volume spelling of the home directory and the data volume root are too broad" do
      {:ok, home} = Minga.Project.Root.canonical_path(Path.expand("~"))
      firmlink = "/System/Volumes/Data" <> home

      if File.dir?(firmlink) do
        assert {:unavailable, {:too_broad, _}} = WorkingFolder.folder(firmlink)
        assert {:unavailable, {:too_broad, _}} = WorkingFolder.folder("/System/Volumes/Data")
      end
    end

    test "a plain folder below the home directory is not too broad", %{tmp_dir: dir} do
      assert {:folder, _root} = WorkingFolder.folder(dir)
    end

    test "every folder above the home directory is too broad" do
      {:ok, home} = Minga.Project.Root.canonical_path(Path.expand("~"))
      above = Path.dirname(home)

      assert {:unavailable, {:too_broad, ^above}} = WorkingFolder.folder(above)

      assert {:unavailable, {:too_broad, ^above}} =
               WorkingFolder.for_file(Path.join(above, "notes.txt"))
    end
  end

  test "the private root of a session without a folder is a real directory of this user only" do
    root = WorkingFolder.root_or_placeholder({:unavailable, :none})

    assert root == WorkingFolder.placeholder_root()
    assert {:ok, %File.Stat{type: :directory, mode: mode}} = File.lstat(root)
    assert Bitwise.band(mode, 0o077) == 0
  end
end
