defmodule MingaEditor.NativeOpenTest do
  use Minga.Test.EditorCase, async: true

  @moduletag :tmp_dir

  alias Minga.Project
  alias Minga.Project.SlowFileFind
  alias MingaEditor.UI.Picker

  test "opening a directory from Finder finds and opens files in the editor's project",
       %{tmp_dir: tmp_dir} do
    events = :"native_open_events_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :duplicate, name: events})

    project_server =
      start_supervised!(
        {Project,
         name: nil,
         subscribe: false,
         command_frecency: %{},
         file_find_module: SlowFileFind,
         events_registry: events}
      )

    project = Path.join(tmp_dir, "project")
    File.mkdir!(project)
    relative_path = "finder-private.txt"
    path = Path.join(project, relative_path)
    File.write!(path, "private Finder result")
    ctx = start_editor("initial", project_server: project_server, events_registry: events)

    assert :ok = MingaEditor.open_native(project, false, ctx.editor)

    assert %{title: "Find file"} = picker_state(ctx)
    assert Project.root(project_server) == project

    Minga.Events.subscribe(:project_rebuilt, events)
    %{rebuild_pid: worker} = :sys.get_state(project_server)
    :ok = SlowFileFind.complete(worker, {:ok, [relative_path]})

    assert_receive {:minga_event, :project_rebuilt,
                    %Minga.Events.ProjectRebuiltEvent{root: ^project}},
                   1_000

    wait_until(
      ctx,
      fn _state ->
        case picker_state(ctx) do
          %Picker{} = picker ->
            match?(%{id: %{path: ^relative_path}}, Picker.selected_item(picker))

          nil ->
            false
        end
      end,
      max_attempts: 100,
      message: "expected Find file to present the private project's discovery result"
    )

    send_key_sync(ctx, 13)
    refute picker_open?(ctx)
    assert Minga.Buffer.file_path(active_window_buffer(ctx)) == path
  end
end
