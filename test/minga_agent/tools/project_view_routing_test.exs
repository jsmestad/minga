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
  alias MingaAgent.Test.RetainedContextFixture
  alias MingaAgent.Tool.Context, as: ToolContext
  alias MingaAgent.Tool.Output
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

  test "discovery and shell tools use ProjectView working dir and env", %{
    tools: tools,
    working_dir: working_dir
  } do
    assert {:ok, list_result} = call_tool(tools, "list_directory", %{"path" => "lib"})
    assert list_result =~ "overlay_only.txt"

    assert {:ok, root_list_result} = call_tool(tools, "list_directory", %{"path" => "."})
    refute root_list_result =~ ".env.local"
    refute root_list_result =~ ".npmrc"
    refute root_list_result =~ "ignored_dir"

    assert {:ok, ignored_root_result} =
             call_tool(tools, "list_directory", %{"path" => "node_modules"})

    refute ignored_root_result =~ "leaked.txt"

    assert {:ok, find_result} =
             call_tool(tools, "find", %{
               "pattern" => "overlay_only.txt",
               "path" => "lib",
               "type" => "file"
             })

    assert find_result =~ "overlay_only.txt"

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
          {"read_file", %{"path" => "lib/view_only.txt"}, :read_failed},
          {"write_file",
           %{
             "path" => "lib/new.txt",
             "mode" => "create",
             "content" => "new",
             "expected_revision" => "absent"
           }, ":write_failed"},
          {"edit_file",
           %{
             "path" => "lib/edit_target.txt",
             "expected_revision" => "revision",
             "edits" => [%{"old_text" => "editable", "new_text" => "changed"}]
           }, ":edit_failed"},
          {"delete_file", %{"path" => "lib/root_only.txt", "expected_revision" => "revision"},
           ":delete_failed"},
          {"list_directory", %{"path" => "lib"}, ":list_failed"}
        ] do
      assert {:error, message} = call_tool(tools, name, args)

      case expected do
        reason when is_atom(reason) ->
          assert message == reason

        text ->
          refute message =~ "project_view_unavailable"
          assert message =~ text
      end
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
               "mode" => "create",
               "expected_revision" => "absent",
               "content" => "new line\n"
             })

    assert write_result =~ "atomic file mutation"

    assert {:ok, edit_result} =
             call_tool(tools, "edit_file", %{
               "path" => "lib/modified.txt",
               "expected_revision" => full_revision(tools, "lib/modified.txt"),
               "edits" => [%{"old_text" => "old", "new_text" => "new"}]
             })

    assert edit_result =~ "atomic file mutation"

    assert {:ok, delete_result} =
             call_tool(tools, "delete_file", %{
               "path" => "lib/deleted.txt",
               "expected_revision" => full_revision(tools, "lib/deleted.txt")
             })

    assert delete_result =~ "atomic file mutation"

    for path <- [".env.local", ".npmrc", "node_modules/pkg/secret.txt", "ignored_dir/secret.txt"] do
      assert {:ok, _result} =
               call_tool(tools, "write_file", %{
                 "path" => path,
                 "mode" => "create",
                 "expected_revision" => "absent",
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
               "mode" => "replace",
               "expected_revision" => full_revision(tools, "lib/file.txt"),
               "content" => "view text\n"
             })

    assert {:ok, _} =
             call_tool(tools, "write_file", %{
               "path" => "lib/new.txt",
               "mode" => "create",
               "content" => "view new\n",
               "expected_revision" => "absent"
             })

    assert {:ok, _} =
             call_tool(tools, "delete_file", %{
               "path" => "lib/delete.txt",
               "expected_revision" => full_revision(tools, "lib/delete.txt")
             })

    for path <- [".env.local", ".npmrc", "node_modules/pkg/secret.txt", "ignored_dir/secret.txt"] do
      assert {:ok, _result} =
               call_tool(tools, "write_file", %{
                 "path" => path,
                 "mode" => "create",
                 "expected_revision" => "absent",
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
               "mode" => "create",
               "expected_revision" => "absent",
               "content" => "shared_secret_token\n"
             })

    assert write_result =~ "atomic file mutation"
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
               "mode" => "replace",
               "expected_revision" => full_revision(tools, "lib/fork_only.txt"),
               "content" => "fork only draft\n"
             })

    assert write_result =~ "atomic file mutation"

    assert {:ok, secret_result} =
             call_tool(tools, "write_file", %{
               "path" => ".env.local",
               "mode" => "replace",
               "expected_revision" => full_revision(tools, ".env.local"),
               "content" => "hidden fork token\n"
             })

    assert secret_result =~ "atomic file mutation"

    assert {:ok, ignored_result} =
             call_tool(tools, "write_file", %{
               "path" => "node_modules/pkg/fork_secret.txt",
               "mode" => "replace",
               "expected_revision" => full_revision(tools, "node_modules/pkg/fork_secret.txt"),
               "content" => "hidden nested fork token\n"
             })

    assert ignored_result =~ "atomic file mutation"

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
               "mode" => "replace",
               "expected_revision" => full_revision(tools, "lib/paths.txt"),
               "content" => "++ new/body kept\nplain\n"
             })

    assert {:ok, _result} =
             call_tool(tools, "write_file", %{
               "path" => "lib/a/old/file.txt",
               "mode" => "replace",
               "expected_revision" => full_revision(tools, "lib/a/old/file.txt"),
               "content" => "new path\n"
             })

    assert {:ok, _result} =
             call_tool(tools, "write_file", %{
               "path" => "old/file with space.txt",
               "mode" => "replace",
               "expected_revision" => full_revision(tools, "old/file with space.txt"),
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

  test "overlay git_diff reports incomplete capture when output exceeds the cap", %{tmp_dir: root} do
    File.mkdir_p!(root)
    {_out, 0} = System.cmd("git", ["init"], cd: root, stderr_to_stdout: true)
    {:ok, changeset} = start_supervised({Changeset.Server, project_root: root})
    big_content = String.duplicate("large diff line\n", 500)
    tools = build_tools(project_root: root, changeset: changeset)

    assert {:ok, _result} =
             call_tool(tools, "write_file", %{
               "path" => "big.txt",
               "mode" => "create",
               "content" => big_content,
               "expected_revision" => "absent"
             })

    context = ToolRouter.context(nil, nil, changeset)
    assert {:error, message} = GitTools.diff(root, [max_output_bytes: 1_024], context)
    assert message =~ "capture incomplete"
    assert message =~ "+large diff line"
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
             call_tool(tools, "write_file", %{
               "path" => "big.txt",
               "mode" => "create",
               "content" => oversized,
               "expected_revision" => "absent"
             })

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
               "mode" => "replace",
               "expected_revision" => full_revision(tools, "lib/large_fork.txt"),
               "content" => oversized
             })

    assert write_result =~ "atomic file mutation"
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
               "mode" => "replace",
               "expected_revision" => full_revision(tools, "lib/project_large_fork.txt"),
               "content" => oversized
             })

    assert write_result =~ "atomic file mutation"
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
               "mode" => "replace",
               "expected_revision" => full_revision(tools, "lib/forked.txt"),
               "content" => "fork draft token\n"
             })

    assert write_result =~ "atomic file mutation"
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

  test "dead changeset edit_file returns an unavailable error without mutating the project",
       %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "lib"))
    target_path = Path.join(root, "lib/edit_target.txt")
    File.write!(target_path, "one two one\n")

    {:ok, changeset} = start_supervised({Changeset.Server, project_root: root})
    tools = build_tools(project_root: root, changeset: changeset)
    revision = full_revision(tools, "lib/edit_target.txt")
    ref = Process.monitor(changeset)
    Process.exit(changeset, :kill)
    assert_receive {:DOWN, ^ref, :process, ^changeset, _reason}

    assert {:error, message} =
             call_tool(tools, "edit_file", %{
               "path" => "lib/edit_target.txt",
               "expected_revision" => revision,
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
    retained = RetainedContextFixture.new(Keyword.fetch!(opts, :project_root), "project-view")

    context =
      opts
      |> Keyword.take([:project_root, :project_view, :fork_store, :changeset])
      |> Keyword.put(:artifact_store, retained.artifact_store)
      |> Keyword.put(
        :metadata,
        MingaAgent.Test.JobSessionStub.metadata(
          start_supervised!({MingaAgent.Test.JobSessionStub, []}, id: make_ref())
        )
      )
      |> ToolContext.new()

    Enum.map(Tools.all(), fn spec ->
      callback = fn args ->
        call_id = "call-#{System.unique_integer([:positive])}"

        scoped =
          ToolContext.for_tool_call(context, context.artifact_store, "project-view", call_id)

        MingaAgent.Tool.Spec.build_callback(spec, scoped).(args)
      end

      %{name: spec.name, callback: callback}
    end)
  end

  defp full_revision(tools, path) do
    tool = Enum.find(tools, &(&1.name == "read_file"))
    assert {:ok, %Output{} = output} = tool.callback.(%{"path" => path})
    assert MingaAgent.Tool.Output.Revision.full_source?(output.revision)
    MingaAgent.Tool.Output.Revision.token(output.revision)
  end

  defp call_tool(tools, name, args) do
    tool = Enum.find(tools, &(&1.name == name))

    case tool.callback.(args) do
      {:ok, %Output{view: view}} -> {:ok, view}
      {:error, %Output{view: view}} -> {:error, view}
      result -> result
    end
  end
end
