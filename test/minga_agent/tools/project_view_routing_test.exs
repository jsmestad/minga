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
    File.write!(Path.join(root, "lib/file.txt"), "root text\n")
    File.write!(Path.join(root, "lib/root_only.txt"), "root only\n")
    File.write!(Path.join(root, "lib/edit_target.txt"), "editable root text\n")
    File.write!(Path.join(working_dir, "lib/file.txt"), "view text\n")
    File.write!(Path.join(working_dir, "lib/overlay_only.txt"), "needle\n")

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

  test "discovery and shell tools use ProjectView working dir and env", %{tools: tools} do
    assert {:ok, list_result} = call_tool(tools, "list_directory", %{"path" => "lib"})
    assert list_result =~ "overlay_only.txt"
    assert list_result =~ "ProjectView workspace 42"
    assert_receive {:project_view_call, {:list_directory, "lib"}}

    assert {:ok, find_result} =
             call_tool(tools, "find", %{
               "pattern" => "overlay_only.txt",
               "path" => "lib",
               "type" => "file"
             })

    assert find_result =~ "overlay_only.txt"
    assert find_result =~ "ProjectView workspace 42"

    assert {:ok, grep_result} =
             call_tool(tools, "grep", %{"pattern" => "needle", "path" => "lib"})

    assert grep_result =~ "overlay_only.txt"
    assert grep_result =~ "ProjectView workspace 42"

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

  test "multi_edit fails closed when configured ProjectView is dead", %{tmp_dir: dir} do
    root = Path.join(dir, "dead-multi-root")
    File.mkdir_p!(Path.join(root, "lib"))
    file = Path.join(root, "lib/file.txt")
    File.write!(file, "root text\n")
    {:ok, view} = ProjectView.overlay(root)
    changeset = view.ref.changeset
    ref = Process.monitor(changeset)
    tools = Tools.all(project_root: root, project_view: view)

    Process.exit(changeset, :kill)
    assert_receive {:DOWN, ^ref, :process, ^changeset, _reason}

    assert {:error, message} =
             call_tool(tools, "multi_edit_file", %{
               "path" => "lib/file.txt",
               "edits" => [%{"old_text" => "root", "new_text" => "changed"}]
             })

    assert message =~ "dead_project_view"
    assert File.read!(file) == "root text\n"
  end

  test "shell checks dead ProjectView before flushing dirty buffers", %{tmp_dir: dir} do
    root = Path.join(dir, "dead-shell-root")
    File.mkdir_p!(Path.join(root, "lib"))
    file = Path.join(root, "lib/file.txt")
    File.write!(file, "root text\n")
    buffer = start_supervised!({BufferProcess, file_path: file}, id: make_ref())
    :ok = BufferProcess.insert_text(buffer, " dirty")
    assert BufferProcess.dirty?(buffer)
    {:ok, view} = ProjectView.overlay(root)
    changeset = view.ref.changeset
    ref = Process.monitor(changeset)
    tools = Tools.all(project_root: root, project_view: view)

    Process.exit(changeset, :kill)
    assert_receive {:DOWN, ^ref, :process, ^changeset, _reason}

    assert {:error, :dead_project_view} =
             call_tool(tools, "shell", %{"command" => "printf should-not-run"})

    assert BufferProcess.dirty?(buffer)
    assert File.read!(file) == "root text\n"
  end

  defp call_tool(tools, name, args) do
    tool = Enum.find(tools, &(&1.name == name))
    tool.callback.(args)
  end
end
