defmodule MingaAgent.Tools.ProjectViewRoutingTest do
  # Uses find, grep, and shell tool callbacks, which spawn OS processes.
  use ExUnit.Case, async: false

  alias Minga.Events
  alias Minga.Events.FileWrittenEvent
  alias MingaAgent.ProjectView
  alias MingaAgent.ProjectView.RecordingBackend
  alias MingaAgent.Tools

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "root")
    working_dir = Path.join(dir, "view")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(working_dir, "lib"))
    File.write!(Path.join(root, "lib/file.txt"), "root text\n")
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

  test "direct ProjectView deletes broadcast a deleted file_written event", %{tmp_dir: dir} do
    root = Path.join(dir, "direct-root")
    File.mkdir_p!(Path.join(root, "lib"))
    path = Path.join(root, "lib/direct.txt")
    File.write!(path, "direct text\n")

    {:ok, view} = ProjectView.direct(root, workspace_id: 99)
    tools = Tools.all(project_root: root, project_view: view)

    Events.subscribe(:file_written)

    assert {:ok, delete_result} = call_tool(tools, "delete_file", %{"path" => "lib/direct.txt"})
    assert delete_result =~ "ProjectView"
    refute File.exists?(path)

    assert_receive {:minga_event, :file_written,
                    %FileWrittenEvent{path: ^path, change_type: :deleted}}
  end

  test "read_file stops at a ProjectView error instead of falling back to root contents", %{
    root: root,
    tools: tools
  } do
    File.write!(Path.join(root, "lib/root_only.txt"), "root text\n")

    assert {:error, error} = call_tool(tools, "read_file", %{"path" => "lib/root_only.txt"})
    assert error =~ "failed to read"
    assert error =~ "ProjectView workspace 42"
    refute error =~ "root text"
    assert_receive {:project_view_call, {:read_file, "lib/root_only.txt"}}
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

  test "multi_edit falls back to direct filesystem when only fork store is active and file is unopened",
       %{tmp_dir: dir} do
    root = Path.join(dir, "fallback-root")
    File.mkdir_p!(Path.join(root, "lib"))
    file = Path.join(root, "lib/unopened.txt")
    File.write!(file, "old text\n")
    {:ok, fork_store} = start_supervised(MingaAgent.BufferForkStore)
    tools = Tools.all(project_root: root, fork_store: fork_store)

    assert {:ok, result} =
             call_tool(tools, "multi_edit_file", %{
               "path" => "lib/unopened.txt",
               "edits" => [%{"old_text" => "old", "new_text" => "new"}]
             })

    assert result =~ "1/1 edits applied"
    assert {:ok, buffer} = Minga.Buffer.pid_for_path(file)
    assert Minga.Buffer.content(buffer) == "new text\n"
  end

  defp call_tool(tools, name, args) do
    tool = Enum.find(tools, &(&1.name == name))
    tool.callback.(args)
  end
end
