defmodule MingaAgent.Tools.ProjectViewRoutingTest do
  # Uses find, grep, and shell tool callbacks, which spawn OS processes.
  use ExUnit.Case, async: false

  # Real discovery, shell, and Git routing remain integration coverage outside the edit loop.
  @moduletag :heavy

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Git.Stub, as: GitStub
  alias MingaAgent.BufferForkStore
  alias MingaAgent.Changeset
  alias MingaAgent.ProjectView.RecordingBackend
  alias MingaAgent.ProjectView.UnavailableBackend
  alias MingaAgent.ToolRouter
  alias MingaAgent.Tools
  alias MingaAgent.Tools.Git, as: GitTools

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

    tools = build_tools(project_root: root, project_view: view)
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

    tools = build_tools(project_root: root, project_view: view)

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
          {"shell", %{"command" => "test -f lib/view_only.txt && echo fallback"}},
          {"git_diff", %{}}
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
    tools = build_tools(project_root: root, changeset: changeset)

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
    tools = build_tools(project_root: root, changeset: changeset)

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

  test "git_diff through changeset reports added modified and deleted overlay files",
       %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "lib"))
    {_out, 0} = System.cmd("git", ["init"], cd: root, stderr_to_stdout: true)
    File.write!(Path.join(root, ".gitignore"), "ignored_dir/\n")
    File.write!(Path.join(root, "lib/modified.txt"), "old line\n")
    File.write!(Path.join(root, "lib/deleted.txt"), "delete me\n")

    {:ok, changeset} = start_supervised({Changeset.Server, project_root: root})
    tools = build_tools(project_root: root, changeset: changeset)

    assert {:ok, write_result} =
             call_tool(tools, "write_file", %{
               "path" => "lib/added.txt",
               "content" => "new line\n"
             })

    assert write_result =~ "via changeset"

    assert {:ok, edit_result} =
             call_tool(tools, "edit_file", %{
               "path" => "lib/modified.txt",
               "old_text" => "old",
               "new_text" => "new"
             })

    assert edit_result =~ "via changeset"
    assert {:ok, delete_result} = call_tool(tools, "delete_file", %{"path" => "lib/deleted.txt"})
    assert delete_result =~ "via changeset"

    for path <- [".env.local", ".npmrc", "node_modules/pkg/secret.txt", "ignored_dir/secret.txt"] do
      assert {:ok, _result} =
               call_tool(tools, "write_file", %{
                 "path" => path,
                 "content" => "hidden overlay token\n"
               })
    end

    assert {:ok, diff} = call_tool(tools, "git_diff", %{})
    assert diff =~ "a/lib/added.txt"
    assert diff =~ "+new line"
    assert diff =~ "a/lib/modified.txt"
    assert diff =~ "-old line"
    assert diff =~ "+new line"
    assert diff =~ "a/lib/deleted.txt"
    assert diff =~ "-delete me"
    refute diff =~ ".env.local"
    refute diff =~ ".npmrc"
    refute diff =~ "node_modules"
    refute diff =~ "ignored_dir"
    refute diff =~ "hidden overlay token"

    assert File.read!(Path.join(root, "lib/modified.txt")) == "old line\n"
    assert File.exists?(Path.join(root, "lib/deleted.txt"))
    refute File.exists?(Path.join(root, "lib/added.txt"))
  end

  test "git_diff through ProjectView overlay reports view-local changes", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "lib"))
    {_out, 0} = System.cmd("git", ["init"], cd: root, stderr_to_stdout: true)
    File.write!(Path.join(root, ".gitignore"), "ignored_dir/\n")
    File.write!(Path.join(root, "lib/file.txt"), "root text\n")
    File.write!(Path.join(root, "lib/delete.txt"), "root delete\n")

    {:ok, view} = MingaAgent.ProjectView.overlay(root)
    tools = build_tools(project_root: root, project_view: view)

    assert {:ok, _} =
             call_tool(tools, "write_file", %{
               "path" => "lib/file.txt",
               "content" => "view text\n"
             })

    assert {:ok, _} =
             call_tool(tools, "write_file", %{"path" => "lib/new.txt", "content" => "view new\n"})

    assert {:ok, _} = call_tool(tools, "delete_file", %{"path" => "lib/delete.txt"})

    for path <- [".env.local", ".npmrc", "node_modules/pkg/secret.txt", "ignored_dir/secret.txt"] do
      assert {:ok, _result} =
               call_tool(tools, "write_file", %{
                 "path" => path,
                 "content" => "hidden project view token\n"
               })
    end

    assert {:ok, diff} = call_tool(tools, "git_diff", %{})
    assert diff =~ "a/lib/file.txt"
    assert diff =~ "-root text"
    assert diff =~ "+view text"
    assert diff =~ "a/lib/new.txt"
    assert diff =~ "+view new"
    assert diff =~ "a/lib/delete.txt"
    assert diff =~ "-root delete"
    refute diff =~ ".env.local"
    refute diff =~ ".npmrc"
    refute diff =~ "node_modules"
    refute diff =~ "ignored_dir"
    refute diff =~ "hidden project view token"

    assert File.read!(Path.join(root, "lib/file.txt")) == "root text\n"
    assert File.exists?(Path.join(root, "lib/delete.txt"))
    refute File.exists?(Path.join(root, "lib/new.txt"))
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
    tools = build_tools(project_root: root, changeset: changeset)

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

    fake_cwd = Path.join(root, "fake-cwd")
    File.mkdir_p!(fake_cwd)
    File.write!(Path.join(fake_cwd, "spoof.txt"), "spoofed\n")
    overlay_dir = Changeset.overlay_path(changeset)

    assert {:ok, shell_result} =
             call_tool(tools, "shell", %{
               "command" =>
                 "printf 'file=%s\nbuild=%s\nevil=%s\nspoof=%s\n' \"$(cat overlay_added.txt 2>/dev/null)\" \"$MIX_BUILD_PATH\" \"${EVIL:-unset}\" \"$(test -f spoof.txt && echo yes || echo no)\"",
               "_cwd" => fake_cwd,
               "_env" => %{"EVIL" => "set"}
             })

    assert shell_result =~ "file=shared_secret_token"
    assert shell_result =~ "build=#{Path.join(overlay_dir, "_build")}"
    assert shell_result =~ "evil=unset"
    assert shell_result =~ "spoof=no"
  end

  test "git_diff through fork store reports open-buffer fork drafts", %{root: root} do
    File.mkdir_p!(Path.join(root, "lib"))
    target_path = Path.join(root, "lib/fork_only.txt")
    secret_path = Path.join(root, ".env.local")
    ignored_path = Path.join(root, "node_modules/pkg/fork_secret.txt")
    File.write!(target_path, "original fork only\n")
    File.write!(secret_path, "original secret\n")

    {:ok, _buffer} =
      start_supervised({BufferProcess, content: "original fork only\n", file_path: target_path},
        id: :fork_only_diff_buffer
      )

    {:ok, _secret_buffer} =
      start_supervised({BufferProcess, content: "original secret\n", file_path: secret_path},
        id: :fork_secret_diff_buffer
      )

    {:ok, _ignored_buffer} =
      start_supervised({BufferProcess, content: "ignored original\n", file_path: ignored_path},
        id: :fork_ignored_diff_buffer
      )

    {:ok, store} = start_supervised(BufferForkStore)
    tools = build_tools(project_root: root, fork_store: store)

    assert {:ok, write_result} =
             call_tool(tools, "write_file", %{
               "path" => "lib/fork_only.txt",
               "content" => "fork only draft\n"
             })

    assert write_result =~ "via fork"

    assert {:ok, secret_result} =
             call_tool(tools, "write_file", %{
               "path" => ".env.local",
               "content" => "hidden fork token\n"
             })

    assert secret_result =~ "via fork"

    assert {:ok, ignored_result} =
             call_tool(tools, "write_file", %{
               "path" => "node_modules/pkg/fork_secret.txt",
               "content" => "hidden nested fork token\n"
             })

    assert ignored_result =~ "via fork"

    assert {:ok, diff_result} = call_tool(tools, "git_diff", %{})
    assert diff_result =~ "a/lib/fork_only.txt"
    assert diff_result =~ "-original fork only"
    assert diff_result =~ "+fork only draft"
    refute diff_result =~ ".env.local"
    refute diff_result =~ "hidden fork token"
    refute diff_result =~ "node_modules"
    refute diff_result =~ "hidden nested fork token"
    assert File.read!(target_path) == "original fork only\n"
    assert File.read!(secret_path) == "original secret\n"
  end

  test "overlay git_diff rejects staged mode without falling back to real repo diff", %{
    tmp_dir: root
  } do
    File.mkdir_p!(root)
    GitStub.set_root(root, root)
    GitStub.set_diff(root, "REAL REPO DIFF\n")
    on_exit(fn -> GitStub.clear(root) end)

    {:ok, changeset} = start_supervised({Changeset.Server, project_root: root})
    tools = build_tools(project_root: root, changeset: changeset)

    assert {:error, message} = call_tool(tools, "git_diff", %{"staged" => true})
    assert message =~ "staged=true is unavailable"
    refute message =~ "REAL REPO DIFF"
  end

  test "overlay git_diff preserves hunk body marker lines while normalizing headers", %{
    tmp_dir: root
  } do
    File.mkdir_p!(Path.join(root, "lib/a/old"))
    File.mkdir_p!(Path.join(root, "old"))
    {_out, 0} = System.cmd("git", ["init"], cd: root, stderr_to_stdout: true)
    File.write!(Path.join(root, "lib/paths.txt"), "-- old/body marker\nplain\n")
    File.write!(Path.join(root, "lib/a/old/file.txt"), "old path\n")
    File.write!(Path.join(root, "old/file with space.txt"), "old spaced path\n")

    {:ok, changeset} = start_supervised({Changeset.Server, project_root: root})
    tools = build_tools(project_root: root, changeset: changeset)

    assert {:ok, _result} =
             call_tool(tools, "write_file", %{
               "path" => "lib/paths.txt",
               "content" => "++ new/body kept\nplain\n"
             })

    assert {:ok, _result} =
             call_tool(tools, "write_file", %{
               "path" => "lib/a/old/file.txt",
               "content" => "new path\n"
             })

    assert {:ok, _result} =
             call_tool(tools, "write_file", %{
               "path" => "old/file with space.txt",
               "content" => "new spaced path\n"
             })

    assert {:ok, diff} = call_tool(tools, "git_diff", %{})
    lines = String.split(diff, "\n")
    assert "diff --git a/lib/paths.txt b/lib/paths.txt" in lines
    assert "diff --git a/lib/a/old/file.txt b/lib/a/old/file.txt" in lines
    assert "--- a/lib/a/old/file.txt" in lines
    assert "+++ b/lib/a/old/file.txt" in lines
    assert "diff --git a/old/file with space.txt b/old/file with space.txt" in lines
    assert "--- a/old/file with space.txt" in lines
    assert "+++ b/old/file with space.txt" in lines
    assert diff =~ "--- old/body marker"
    assert diff =~ "+++ new/body kept"
    refute diff =~ "--- a/body marker"
    refute diff =~ "+++ b/body kept"
    refute diff =~ "diff --git a/lib/a/file.txt b/lib/a/file.txt"
    refute diff =~ "b/new/old/file with space.txt"
  end

  test "overlay git_diff refuses symlink paths instead of reading outside contents", %{
    root: root
  } do
    working_dir = Path.join(root, "../symlink-view")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(working_dir, "lib"))
    outside_path = Path.join(root, "../outside-secret.txt")
    link_path = Path.join(root, "lib/link.txt")
    File.write!(outside_path, "outside secret token\n")
    File.ln_s!(outside_path, link_path)
    File.write!(Path.join(working_dir, "lib/link.txt"), "draft\n")

    {:ok, view} =
      RecordingBackend.create(root,
        parent: self(),
        working_dir: working_dir,
        diff: [%{path: "lib/link.txt", kind: :modified}]
      )

    assert {:ok, [%{path: "lib/link.txt"}]} = MingaAgent.ProjectView.diff(view)
    tools = build_tools(project_root: root, project_view: view)
    assert {:error, message} = call_tool(tools, "git_diff", %{})
    assert message =~ "refusing to diff symlink path lib/link.txt"
    refute message =~ "outside secret token"
  end

  test "overlay git_diff caps large no-index diff output", %{tmp_dir: root} do
    File.mkdir_p!(root)
    {_out, 0} = System.cmd("git", ["init"], cd: root, stderr_to_stdout: true)
    {:ok, changeset} = start_supervised({Changeset.Server, project_root: root})
    big_content = String.duplicate("large diff line\n", 500)
    tools = build_tools(project_root: root, changeset: changeset)

    assert {:ok, _result} =
             call_tool(tools, "write_file", %{"path" => "big.txt", "content" => big_content})

    context = ToolRouter.context(nil, nil, changeset)
    assert {:ok, diff} = GitTools.diff(root, [max_output_bytes: 1_024], context)
    assert byte_size(diff) < 2_000
    assert diff =~ "[truncated at 1KB]"
  end

  test "overlay git_diff fails closed when one overlay file exceeds input cap", %{tmp_dir: root} do
    File.mkdir_p!(root)
    {_out, 0} = System.cmd("git", ["init"], cd: root, stderr_to_stdout: true)
    GitStub.set_root(root, root)
    GitStub.set_diff(root, "REAL REPO DIFF\n")
    on_exit(fn -> GitStub.clear(root) end)

    {:ok, changeset} = start_supervised({Changeset.Server, project_root: root})
    oversized = String.duplicate("oversized secret token\n", 20)
    tools = build_tools(project_root: root, changeset: changeset)

    assert {:ok, _result} =
             call_tool(tools, "write_file", %{"path" => "big.txt", "content" => oversized})

    context = ToolRouter.context(nil, nil, changeset)
    assert {:error, message} = GitTools.diff(root, [max_input_bytes: 8], context)
    assert message =~ "git_diff input file too large: big.txt exceeds 8 bytes"
    refute message =~ "oversized secret token"
    refute message =~ "REAL REPO DIFF"
    refute File.exists?(Path.join(root, "big.txt"))
  end

  test "combined fork store and changeset git_diff rejects over-cap fork before materializing", %{
    root: root
  } do
    File.mkdir_p!(Path.join(root, "lib"))
    target_path = Path.join(root, "lib/large_fork.txt")
    File.write!(target_path, "original\n")

    {:ok, _buffer} =
      start_supervised({BufferProcess, content: "original\n", file_path: target_path},
        id: :large_combined_diff_buffer
      )

    {:ok, store} = start_supervised(BufferForkStore)
    {:ok, changeset} = start_supervised({Changeset.Server, project_root: root})
    tools = build_tools(project_root: root, fork_store: store, changeset: changeset)
    oversized = String.duplicate("combined fork secret\n", 20)

    assert {:ok, write_result} =
             call_tool(tools, "write_file", %{
               "path" => "lib/large_fork.txt",
               "content" => oversized
             })

    assert write_result =~ "via fork"
    context = ToolRouter.context(nil, store, changeset)
    overlay_file = Path.join(Changeset.overlay_path(changeset), "lib/large_fork.txt")

    assert {:error, message} = GitTools.diff(root, [max_input_bytes: 8], context)
    assert message =~ "git_diff input file too large: lib/large_fork.txt exceeds 8 bytes"
    refute message =~ "combined fork secret"
    refute File.exists?(overlay_file)
    assert File.read!(target_path) == "original\n"
  end

  test "ProjectView git_diff rejects over-cap fork before preparing overlay", %{root: root} do
    File.mkdir_p!(Path.join(root, "lib"))
    target_path = Path.join(root, "lib/project_large_fork.txt")
    File.write!(target_path, "original\n")

    {:ok, _buffer} =
      start_supervised({BufferProcess, content: "original\n", file_path: target_path},
        id: :large_project_view_diff_buffer
      )

    {:ok, view} = MingaAgent.ProjectView.overlay(root)
    tools = build_tools(project_root: root, project_view: view)
    oversized = String.duplicate("project view fork secret\n", 20)

    assert {:ok, write_result} =
             call_tool(tools, "write_file", %{
               "path" => "lib/project_large_fork.txt",
               "content" => oversized
             })

    assert write_result =~ "via ProjectView"
    context = ToolRouter.context(view, nil, nil)

    overlay_file =
      Path.join(MingaAgent.ProjectView.working_dir(view), "lib/project_large_fork.txt")

    assert {:error, message} = GitTools.diff(root, [max_input_bytes: 8], context)
    assert message =~ "git_diff input file too large: lib/project_large_fork.txt exceeds 8 bytes"
    refute message =~ "project view fork secret"
    refute File.exists?(overlay_file)
    assert File.read!(target_path) == "original\n"
  end

  test "combined fork store and changeset search and shell see open-buffer fork drafts", %{
    root: root
  } do
    File.mkdir_p!(Path.join(root, "lib"))
    target_path = Path.join(root, "lib/forked.txt")
    File.write!(target_path, "original text\n")

    {:ok, _buffer} =
      start_supervised({BufferProcess, content: "original text\n", file_path: target_path},
        id: :combined_overlay_buffer
      )

    {:ok, store} = start_supervised(BufferForkStore)
    {:ok, changeset} = start_supervised({Changeset.Server, project_root: root})
    tools = build_tools(project_root: root, fork_store: store, changeset: changeset)

    assert {:ok, write_result} =
             call_tool(tools, "write_file", %{
               "path" => "lib/forked.txt",
               "content" => "fork draft token\n"
             })

    assert write_result =~ "via fork"
    assert File.read!(target_path) == "original text\n"

    assert {:ok, grep_result} =
             call_tool(tools, "grep", %{"pattern" => "fork draft token", "path" => "lib"})

    assert grep_result =~ "forked.txt"

    assert {:ok, shell_result} =
             call_tool(tools, "shell", %{"command" => "cat lib/forked.txt"})

    assert shell_result =~ "fork draft token"

    assert {:ok, diff_result} = call_tool(tools, "git_diff", %{})
    assert diff_result =~ "a/lib/forked.txt"
    assert diff_result =~ "-original text"
    assert diff_result =~ "+fork draft token"
    assert File.read!(target_path) == "original text\n"
  end

  test "dead changeset git_diff fails closed instead of returning real repo diff", %{
    tmp_dir: root
  } do
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/file.txt"), "real repo\n")
    GitStub.set_root(root, root)
    GitStub.set_diff(root, "REAL REPO DIFF\n")
    on_exit(fn -> GitStub.clear(root) end)

    {:ok, changeset} = start_supervised({Changeset.Server, project_root: root})
    tools = build_tools(project_root: root, changeset: changeset)
    ref = Process.monitor(changeset)
    Process.exit(changeset, :kill)
    assert_receive {:DOWN, ^ref, :process, ^changeset, _reason}

    assert {:error, message} = call_tool(tools, "git_diff", %{})
    assert message =~ "changeset working directory unavailable"
    refute message =~ "REAL REPO DIFF"
  end

  test "dead changeset multi_edit_file returns an unavailable error without mutating the project",
       %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "lib"))
    target_path = Path.join(root, "lib/edit_target.txt")
    File.write!(target_path, "one two one\n")

    {:ok, changeset} = start_supervised({Changeset.Server, project_root: root})
    tools = build_tools(project_root: root, changeset: changeset)
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

    tools = build_tools(project_root: root, project_view: view)

    assert {:error, message} = call_tool(tools, "shell", %{"command" => "cat lib/dirty.txt"})
    assert message =~ "project_view_unavailable"
    assert File.read!(file) == "original\n"
    assert Minga.Buffer.content(buffer) == "dirty\n"
  end

  defp build_tools(opts) do
    context =
      opts
      |> Keyword.take([:project_root, :project_view, :fork_store, :changeset])
      |> MingaAgent.Tool.Context.new()

    Enum.map(Tools.all(), fn spec ->
      %{name: spec.name, callback: MingaAgent.Tool.Spec.build_callback(spec, context)}
    end)
  end

  defp call_tool(tools, name, args) do
    tool = Enum.find(tools, &(&1.name == name))
    tool.callback.(args)
  end
end
