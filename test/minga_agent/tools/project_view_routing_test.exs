defmodule MingaAgent.Tools.ProjectViewRoutingTest do
  # Uses find, grep, and shell tool callbacks, which spawn OS processes.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaAgent.Changeset
  alias MingaAgent.ProjectView.RecordingBackend
  alias MingaAgent.ProjectView.UnavailableBackend
  alias MingaAgent.Tools

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "root")
    working_dir = Path.join(dir, "view")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(working_dir, "lib"))
    {_out, 0} = System.cmd("git", ["init"], cd: root, stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["init"], cd: working_dir, stderr_to_stdout: true)
    File.write!(Path.join(root, ".gitignore"), "ignored_dir/\n")
    File.write!(Path.join(root, "lib/file.txt"), "root text\n")
    File.write!(Path.join(root, "lib/root_only.txt"), "root only\n")
    File.write!(Path.join(root, "lib/edit_target.txt"), "editable root text\n")
    File.write!(Path.join(working_dir, "lib/file.txt"), "view text\n")
    File.write!(Path.join(working_dir, "lib/overlay_only.txt"), "needle\n")
    File.write!(Path.join(working_dir, "visible_secret.txt"), "shared_secret_token\n")
    File.write!(Path.join(working_dir, ".env.local"), "shared_secret_token\n")
    File.write!(Path.join(working_dir, ".npmrc"), "shared_secret_token\n")
    File.mkdir_p!(Path.join(root, "ignored_dir"))
    File.mkdir_p!(Path.join(working_dir, "ignored_dir"))
    File.write!(Path.join(working_dir, "ignored_dir/leaked.txt"), "shared_secret_token\n")
    File.mkdir_p!(Path.join(root, "node_modules"))
    File.mkdir_p!(Path.join(working_dir, "node_modules"))
    File.write!(Path.join(working_dir, "node_modules/leaked.txt"), "shared_secret_token\n")

    {:ok, view} =
      RecordingBackend.create(root,
        parent: self(),
        working_dir: working_dir,
        workspace_id: 42,
        env: [{"PROJECT_VIEW_SENTINEL", "present"}]
      )

    tools = Tools.all(project_root: root, project_view: view)
    %{root: root, working_dir: working_dir, tools: tools}
  end

  test "file tools route through ProjectView and leave project root unchanged", %{
    root: root,
    working_dir: working_dir,
    tools: tools
  } do
    assert {:ok, read_result} = call_tool(tools, "read_file", %{"path" => "lib/file.txt"})
    assert read_result =~ "view text"
    assert read_result =~ "ProjectView workspace 42"
    assert_receive {:project_view_call, {:read_file, "lib/file.txt"}}

    assert {:ok, write_result} =
             call_tool(tools, "write_file", %{"path" => "lib/new.txt", "content" => "new view"})

    assert write_result =~ "via ProjectView"
    assert File.read!(Path.join(working_dir, "lib/new.txt")) == "new view"
    refute File.exists?(Path.join(root, "lib/new.txt"))
    assert_receive {:project_view_call, {:write_file, "lib/new.txt", "new view"}}

    assert {:ok, edit_result} =
             call_tool(tools, "edit_file", %{
               "path" => "lib/file.txt",
               "old_text" => "view",
               "new_text" => "edited"
             })

    assert edit_result =~ "via ProjectView"
    assert File.read!(Path.join(working_dir, "lib/file.txt")) == "edited text\n"
    assert File.read!(Path.join(root, "lib/file.txt")) == "root text\n"
    assert_receive {:project_view_call, {:edit_file, "lib/file.txt", "view", "edited"}}

    assert {:ok, multi_result} =
             call_tool(tools, "multi_edit_file", %{
               "path" => "lib/file.txt",
               "edits" => [%{"old_text" => "edited", "new_text" => "multi"}]
             })

    assert multi_result =~ "via ProjectView"
    assert multi_result =~ "ProjectView workspace 42"
    assert File.read!(Path.join(working_dir, "lib/file.txt")) == "multi text\n"
    assert_receive {:project_view_call, {:read_file, "lib/file.txt"}}
    assert_receive {:project_view_call, {:write_file, "lib/file.txt", "multi text\n"}}

    diff = """
    @@ -1,1 +1,1 @@
    -multi text
    +diff text
    """

    assert {:ok, diff_result} =
             call_tool(tools, "apply_diff", %{"path" => "lib/file.txt", "diff" => diff})

    assert diff_result =~ "via ProjectView"
    assert diff_result =~ "ProjectView workspace 42"
    assert File.read!(Path.join(working_dir, "lib/file.txt")) == "diff text\n"
    assert_receive {:project_view_call, {:read_file, "lib/file.txt"}}
    assert_receive {:project_view_call, {:write_file, "lib/file.txt", "diff text\n"}}

    assert {:ok, delete_result} = call_tool(tools, "delete_file", %{"path" => "lib/new.txt"})
    assert delete_result =~ "ProjectView"
    refute File.exists?(Path.join(working_dir, "lib/new.txt"))
    assert_receive {:project_view_call, {:delete_file, "lib/new.txt"}}
  end

  test "multi_edit_file through ProjectView rejects empty old_text without writing", %{
    root: root,
    working_dir: working_dir,
    tools: tools
  } do
    assert {:ok, result} =
             call_tool(tools, "multi_edit_file", %{
               "path" => "lib/file.txt",
               "edits" => [%{"old_text" => "", "new_text" => "ignored"}]
             })

    assert result =~ "applied 0/1 edits"
    assert result =~ "old_text is empty"
    assert_receive {:project_view_call, {:read_file, "lib/file.txt"}}
    refute_receive {:project_view_call, {:write_file, "lib/file.txt", _}}
    assert File.read!(Path.join(working_dir, "lib/file.txt")) == "view text\n"
    assert File.read!(Path.join(root, "lib/file.txt")) == "root text\n"
  end

  test "multi_edit_file through ProjectView rejects ambiguous old_text without writing", %{
    working_dir: working_dir,
    tools: tools
  } do
    ambiguous_path = Path.join(working_dir, "lib/ambiguous.txt")
    File.write!(ambiguous_path, "hello world hello world")

    assert {:ok, result} =
             call_tool(tools, "multi_edit_file", %{
               "path" => "lib/ambiguous.txt",
               "edits" => [%{"old_text" => "hello world", "new_text" => "goodbye"}]
             })

    assert result =~ "applied 0/1 edits"
    assert result =~ "old_text found 2 times (ambiguous)"
    assert_receive {:project_view_call, {:read_file, "lib/ambiguous.txt"}}
    refute_receive {:project_view_call, {:write_file, "lib/ambiguous.txt", _}}
    assert File.read!(ambiguous_path) == "hello world hello world"
  end

  test "discovery and shell tools use ProjectView working dir and env", %{
    tools: tools,
    working_dir: working_dir
  } do
    assert {:ok, list_result} = call_tool(tools, "list_directory", %{"path" => "lib"})
    assert list_result =~ "overlay_only.txt"
    assert list_result =~ "ProjectView workspace 42"
    assert_receive {:project_view_call, {:list_directory, "lib"}}

    assert {:ok, root_list_result} = call_tool(tools, "list_directory", %{"path" => "."})
    refute root_list_result =~ ".env.local"
    refute root_list_result =~ ".npmrc"
    refute root_list_result =~ "ignored_dir"
    assert_receive {:project_view_call, {:list_directory, ""}}

    assert {:ok, ignored_root_result} =
             call_tool(tools, "list_directory", %{"path" => "node_modules"})

    assert ignored_root_result =~ "ProjectView workspace 42"
    refute ignored_root_result =~ "leaked.txt"
    assert_receive {:project_view_call, {:list_directory, "node_modules"}}

    assert {:ok, find_result} =
             call_tool(tools, "find", %{
               "pattern" => "overlay_only.txt",
               "path" => "lib",
               "type" => "file"
             })

    assert find_result =~ "overlay_only.txt"
    assert find_result =~ "ProjectView workspace 42"

    assert {:ok, broad_find_result} =
             call_tool(tools, "find", %{
               "pattern" => "*",
               "path" => ".",
               "type" => "file",
               "_filter_root" => working_dir,
               "_max_output_bytes" => 1_000_000,
               "_timeout_ms" => 1_000_000
             })

    assert broad_find_result =~ "visible_secret.txt"
    refute broad_find_result =~ ".env.local"
    refute broad_find_result =~ ".npmrc"
    refute broad_find_result =~ "node_modules"
    refute broad_find_result =~ "ignored_dir"

    assert {:ok, ignored_find_result} =
             call_tool(tools, "find", %{"pattern" => "*", "path" => "ignored_dir"})

    assert ignored_find_result =~ "No matches found."
    refute ignored_find_result =~ "leaked.txt"

    assert {:ok, grep_result} =
             call_tool(tools, "grep", %{"pattern" => "needle", "path" => "lib"})

    assert grep_result =~ "overlay_only.txt"
    assert grep_result =~ "ProjectView workspace 42"

    assert {:ok, broad_grep_result} =
             call_tool(tools, "grep", %{
               "pattern" => "shared_secret_token",
               "path" => ".",
               "_filter_root" => working_dir,
               "_max_output_bytes" => 1_000_000,
               "_timeout_ms" => 1_000_000
             })

    assert broad_grep_result =~ "visible_secret.txt"
    refute broad_grep_result =~ ".env.local"
    refute broad_grep_result =~ ".npmrc"
    refute broad_grep_result =~ "node_modules"
    refute broad_grep_result =~ "ignored_dir"

    assert {:ok, ignored_grep_result} =
             call_tool(tools, "grep", %{
               "pattern" => "shared_secret_token",
               "path" => "ignored_dir"
             })

    assert ignored_grep_result =~ "No matches found."
    refute ignored_grep_result =~ "leaked.txt"

    assert {:ok, shell_result} =
             call_tool(tools, "shell", %{
               "command" =>
                 "printf '%s:%s' \"$PROJECT_VIEW_SENTINEL\" \"$(test -f lib/overlay_only.txt && echo yes)\""
             })

    assert shell_result =~ "present:yes"
    assert shell_result =~ "ProjectView workspace 42"
    assert_receive {:project_view_call, :command_env}
  end

  test "project view operation errors stay visible while cwd-dependent tools report unavailability",
       %{tmp_dir: root} do
    view_root = Path.join(root, "view")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(view_root, "lib"))
    File.write!(Path.join(root, "lib/root_only.txt"), "root only\n")
    File.write!(Path.join(root, "lib/edit_target.txt"), "editable root text\n")
    File.write!(Path.join(view_root, "lib/view_only.txt"), "view only\n")

    {:ok, view} =
      UnavailableBackend.create(root,
        parent: self(),
        working_dir: view_root,
        workspace_id: 99
      )

    tools = Tools.all(project_root: root, project_view: view)

    for {name, args, expected} <- [
          {"read_file", %{"path" => "lib/view_only.txt"}, ":read_failed"},
          {"write_file", %{"path" => "lib/new.txt", "content" => "new"}, ":write_failed"},
          {"edit_file",
           %{"path" => "lib/edit_target.txt", "old_text" => "editable", "new_text" => "changed"},
           ":edit_failed"},
          {"delete_file", %{"path" => "lib/root_only.txt"}, ":delete_failed"},
          {"multi_edit_file",
           %{
             "path" => "lib/edit_target.txt",
             "edits" => [%{"old_text" => "editable", "new_text" => "changed"}]
           }, ":read_failed"},
          {"apply_diff",
           %{
             "path" => "lib/edit_target.txt",
             "diff" => "@@ -1,1 +1,1 @@\n-editable root text\n+changed\n"
           }, ":read_failed"},
          {"list_directory", %{"path" => "lib"}, ":list_failed"}
        ] do
      assert {:error, message} = call_tool(tools, name, args)
      refute message =~ "project_view_unavailable"
      assert message =~ expected
    end

    for {name, args} <- [
          {"find", %{"pattern" => "view_only.txt", "path" => "lib"}},
          {"grep", %{"pattern" => "view only", "path" => "lib"}},
          {"shell", %{"command" => "test -f lib/view_only.txt && echo fallback"}}
        ] do
      assert {:error, message} = call_tool(tools, name, args)
      assert message =~ "project_view_unavailable"
    end

    assert File.exists?(Path.join(root, "lib/root_only.txt"))
    assert File.read!(Path.join(root, "lib/edit_target.txt")) == "editable root text\n"
    refute File.exists?(Path.join(root, "lib/new.txt"))
  end

  test "multi_edit_file through changeset applies exact edits and leaves real files unchanged",
       %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "lib"))
    target_path = Path.join(root, "lib/edit_target.txt")
    File.write!(target_path, "one two one\n")

    {:ok, changeset} = start_supervised({Changeset.Server, project_root: root})
    tools = Tools.all(project_root: root, changeset: changeset)

    assert {:ok, result} =
             call_tool(tools, "multi_edit_file", %{
               "path" => "lib/edit_target.txt",
               "edits" => [%{"old_text" => "one two", "new_text" => "ONE TWO"}]
             })

    assert result =~ "via changeset"
    assert {:ok, changed} = Changeset.read_file(changeset, "lib/edit_target.txt")
    assert changed == "ONE TWO one\n"
    assert File.read!(target_path) == "one two one\n"
  end

  test "apply_diff through changeset applies unified diffs and leaves real files unchanged",
       %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "lib"))
    target_path = Path.join(root, "lib/diff_target.txt")
    File.write!(target_path, "one\ntwo\n")

    {:ok, changeset} = start_supervised({Changeset.Server, project_root: root})
    tools = Tools.all(project_root: root, changeset: changeset)

    diff = """
    @@ -1,2 +1,2 @@
     one
    -two
    +TWO
    """

    assert {:ok, result} =
             call_tool(tools, "apply_diff", %{"path" => "lib/diff_target.txt", "diff" => diff})

    assert result =~ "via changeset"
    assert {:ok, changed} = Changeset.read_file(changeset, "lib/diff_target.txt")
    assert changed == "one\nTWO\n"
    assert File.read!(target_path) == "one\ntwo\n"
  end

  test "list_directory through changeset suppresses secret entries and ignored roots",
       %{tmp_dir: root} do
    File.mkdir_p!(root)
    {_out, 0} = System.cmd("git", ["init"], cd: root, stderr_to_stdout: true)
    File.write!(Path.join(root, ".gitignore"), "ignored_dir/\n")
    File.write!(Path.join(root, "visible.txt"), "visible\n")
    File.write!(Path.join(root, "visible_secret.txt"), "shared_secret_token\n")
    File.write!(Path.join(root, ".env.local"), "shared_secret_token\n")
    File.write!(Path.join(root, ".npmrc"), "shared_secret_token\n")
    File.mkdir_p!(Path.join(root, "ignored_dir"))
    File.write!(Path.join(root, "ignored_dir/leaked.txt"), "shared_secret_token\n")
    File.mkdir_p!(Path.join(root, "node_modules"))
    File.write!(Path.join(root, "node_modules/leaked.txt"), "shared_secret_token\n")

    {:ok, changeset} = start_supervised({Changeset.Server, project_root: root})
    tools = Tools.all(project_root: root, changeset: changeset)

    assert {:ok, write_result} =
             call_tool(tools, "write_file", %{
               "path" => "overlay_added.txt",
               "content" => "shared_secret_token\n"
             })

    assert write_result =~ "via changeset"
    refute File.exists?(Path.join(root, "overlay_added.txt"))

    assert {:ok, result} = call_tool(tools, "list_directory", %{"path" => "."})
    assert result =~ "visible.txt"
    refute result =~ ".env.local"
    refute result =~ ".npmrc"
    refute result =~ "ignored_dir"

    assert {:ok, ignored_root_result} =
             call_tool(tools, "list_directory", %{"path" => "node_modules"})

    refute ignored_root_result =~ "leaked.txt"

    assert {:ok, find_result} = call_tool(tools, "find", %{"pattern" => "*", "path" => "."})
    assert find_result =~ "visible_secret.txt"
    assert find_result =~ "overlay_added.txt"
    refute find_result =~ ".env.local"
    refute find_result =~ ".npmrc"
    refute find_result =~ "ignored_dir"
    refute find_result =~ "node_modules"

    assert {:ok, grep_result} =
             call_tool(tools, "grep", %{"pattern" => "shared_secret_token", "path" => "."})

    assert grep_result =~ "visible_secret.txt"
    assert grep_result =~ "overlay_added.txt"
    refute grep_result =~ ".env.local"
    refute grep_result =~ ".npmrc"
    refute grep_result =~ "ignored_dir"
    refute grep_result =~ "node_modules"
  end

  test "dead changeset multi_edit_file returns an unavailable error without mutating the project",
       %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "lib"))
    target_path = Path.join(root, "lib/edit_target.txt")
    File.write!(target_path, "one two one\n")

    {:ok, changeset} = start_supervised({Changeset.Server, project_root: root})
    tools = Tools.all(project_root: root, changeset: changeset)
    ref = Process.monitor(changeset)
    Process.exit(changeset, :kill)
    assert_receive {:DOWN, ^ref, :process, ^changeset, _reason}

    assert {:error, message} =
             call_tool(tools, "multi_edit_file", %{
               "path" => "lib/edit_target.txt",
               "edits" => [%{"old_text" => "one", "new_text" => "ONE"}]
             })

    assert message =~ "changeset_unavailable"
    assert File.read!(target_path) == "one two one\n"
  end

  test "shell does not flush dirty buffers when routed cwd resolution fails", %{tmp_dir: dir} do
    root = Path.join(dir, "shell-root")
    view_root = Path.join(dir, "shell-view")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(view_root, "lib"))
    file = Path.join(root, "lib/dirty.txt")
    File.write!(file, "original\n")

    {:ok, buffer} =
      start_supervised({BufferProcess, content: "original\n", file_path: file},
        id: :dirty_shell_buffer
      )

    :ok = Minga.Buffer.replace_content(buffer, "dirty\n")

    {:ok, view} =
      UnavailableBackend.create(root,
        parent: self(),
        working_dir: view_root,
        workspace_id: 100
      )

    tools = Tools.all(project_root: root, project_view: view)

    assert {:error, message} = call_tool(tools, "shell", %{"command" => "cat lib/dirty.txt"})
    assert message =~ "project_view_unavailable"
    assert File.read!(file) == "original\n"
    assert Minga.Buffer.content(buffer) == "dirty\n"
  end

  defp call_tool(tools, name, args) do
    tool = Enum.find(tools, &(&1.name == name))
    tool.callback.(args)
  end
end
