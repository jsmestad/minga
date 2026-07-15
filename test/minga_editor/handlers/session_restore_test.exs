defmodule MingaEditor.Handlers.SessionRestoreTest do
  # Uses the application-wide buffer supervisor and event registry while restoring real file buffers.
  use ExUnit.Case, async: false

  alias Minga.Parser.Manager
  alias Minga.Session
  alias Minga.Session.BufferEntry
  alias Minga.Session.Snapshot
  alias MingaEditor.Handlers.HighlightHandler
  alias MingaEditor.Handlers.SessionRestore
  alias MingaEditor.HighlightSync
  alias MingaEditor.Startup
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.TabBar

  @moduletag :tmp_dir

  test "late parser results survive switching between restored tabs", %{tmp_dir: dir} do
    first_path = Path.join(dir, "first.ex")
    second_path = Path.join(dir, "second.ex")
    File.write!(first_path, "defmodule First do\nend\n")
    File.write!(second_path, "defmodule Second do\nend\n")

    snapshot = %Snapshot{
      version: 1,
      buffers: [%BufferEntry{file: first_path}, %BufferEntry{file: second_path}],
      active_file: first_path
    }

    assert :ok = Session.save(snapshot, session_dir: dir)

    restored = dir |> initial_state() |> SessionRestore.restore_session()
    assert [_, _] = TabBar.visible_file_tabs(restored.shell_runtime.state.tab_bar)
    assert Minga.Buffer.file_path(restored.workspace.buffers.active) == first_path

    second_tab =
      Enum.find(TabBar.visible_file_tabs(restored.shell_runtime.state.tab_bar), fn tab ->
        tab.label == "second.ex"
      end)

    second_buffer = second_tab.context.buffers.active
    assert Minga.Buffer.file_path(second_buffer) == second_path

    assert Manager.buffer_id(second_buffer, restored.parser.parser_manager) > 0

    {with_names, []} =
      HighlightHandler.handle(
        restored,
        {:minga_highlight, {:highlight_names, second_buffer, ["keyword"]}}
      )

    spans = [%{start_byte: 0, end_byte: 9, capture_id: 0}]

    {with_spans, _effects} =
      HighlightHandler.handle(
        with_names,
        {:minga_highlight, {:highlight_spans, second_buffer, spans}}
      )

    switched = MingaEditor.TabWorkflow.switch(with_spans, second_tab.id)
    highlight = HighlightSync.get_highlight(switched, second_buffer)

    assert highlight.capture_names == {"keyword"}
    assert highlight.spans == List.to_tuple(spans)
    assert switched.parser.highlighting == with_spans.parser.highlighting
    assert switched.parser.injection_ranges == with_spans.parser.injection_ranges
  end

  test "restoring loose files under a marker-bearing home keeps the workspace unset", %{
    tmp_dir: dir
  } do
    fake_home = Path.join(dir, "home")
    File.mkdir_p!(fake_home)
    File.write!(Path.join(fake_home, "package.json"), "{}")
    first_path = Path.join(fake_home, "notes.org")
    second_path = Path.join(fake_home, "cacheless_design.org")
    File.write!(first_path, "notes")
    File.write!(second_path, "design")

    snapshot = %Snapshot{
      version: 1,
      buffers: [%BufferEntry{file: first_path}, %BufferEntry{file: second_path}],
      active_file: first_path
    }

    assert :ok = Session.save(snapshot, session_dir: dir)
    Minga.Project.close()
    _ = :sys.get_state(Minga.Project)
    known_before = Minga.Project.known_projects()

    restored = dir |> initial_state(project_root: nil) |> SessionRestore.restore_session()
    project_state = :sys.get_state(Minga.Project)

    assert Minga.Project.root() == nil
    assert Minga.Project.workspace_root() == nil
    assert project_state.workspace == nil
    assert Minga.Project.files() == []
    assert Minga.Project.known_projects() == known_before
    refute fake_home in Minga.Project.known_projects()
    assert restored.workspace.file_tree.project_root == nil
    assert Minga.Buffer.file_path(restored.workspace.buffers.active) == first_path
  end

  test "already-read recovered contents are applied by the SessionRestore owner", %{tmp_dir: dir} do
    path = Path.join(dir, "recovered.ex")
    File.write!(path, "old\n")
    state = initial_state(dir)
    entry = %{path: path, swap_path: Path.join(dir, "recovered.swap"), swap_mtime: 0}

    recovered = SessionRestore.apply_recovered_entries(state, [{entry, {:ok, path, "new\n"}}])
    buffer = recovered.workspace.buffers.active

    assert Minga.Buffer.file_path(buffer) == path
    assert Minga.Buffer.content(buffer) == "new\n"
  end

  test "a deleted saved active file is not reopened as an empty buffer", %{tmp_dir: dir} do
    existing_path = Path.join(dir, "existing.ex")
    missing_path = Path.join(dir, "deleted.ex")
    File.write!(existing_path, "defmodule Existing do\nend\n")

    snapshot = %Snapshot{
      version: 1,
      buffers: [%BufferEntry{file: existing_path}, %BufferEntry{file: missing_path}],
      active_file: missing_path
    }

    assert :ok = Session.save(snapshot, session_dir: dir)

    restored = dir |> initial_state() |> SessionRestore.restore_session()

    assert [_] = TabBar.visible_file_tabs(restored.shell_runtime.state.tab_bar)
    assert Minga.Buffer.file_path(restored.workspace.buffers.active) == existing_path
    refute File.exists?(missing_path)
  end

  @spec initial_state(String.t(), keyword()) :: EditorState.t()
  defp initial_state(dir, opts \\ []) do
    manager_name = Module.concat(__MODULE__, "Parser#{System.unique_integer([:positive])}")

    manager =
      start_supervised!({Manager, name: manager_name, parser_path: "/missing/minga-parser"})

    sidebar = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({MingaEditor.Extension.Sidebar, name: sidebar, notify: false})

    Startup.build_initial_state(
      backend: :headless,
      port_manager: nil,
      parser_manager: manager,
      sidebar_registry: sidebar,
      session_dir: dir,
      project_root: Keyword.get(opts, :project_root, dir)
    )
  end
end
