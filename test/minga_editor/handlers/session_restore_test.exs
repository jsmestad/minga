defmodule MingaEditor.Handlers.SessionRestoreTest do
  # Uses the application-wide buffer supervisor and event registry while restoring real file buffers.
  use ExUnit.Case, async: false

  alias Minga.Language.Highlight.Span
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

    assert :ok = Session.save(snapshot, session_dir: dir, project_root: dir)

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

    spans = [Span.new(0, 9, 0)]

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

  test "non-headless session restore schedules one post-batch LSP refresh", %{tmp_dir: dir} do
    first_path = Path.join(dir, "first.ex")
    second_path = Path.join(dir, "second.ex")
    File.write!(first_path, "defmodule First do\nend\n")
    File.write!(second_path, "defmodule Second do\nend\n")

    snapshot = %Snapshot{
      version: 1,
      buffers: [%BufferEntry{file: first_path}, %BufferEntry{file: second_path}],
      active_file: first_path
    }

    assert :ok = Session.save(snapshot, session_dir: dir, project_root: dir)

    %EditorState{} = state = initial_state(dir)

    restored =
      SessionRestore.restore_session(%{state | frontend: %{state.frontend | backend: :tui}})

    assert [_, _] = TabBar.visible_file_tabs(restored.shell_runtime.state.tab_bar)
    assert Minga.Buffer.file_path(restored.workspace.buffers.active) == first_path
    assert_receive :request_code_lens_and_inlay_hints, 5_000
    refute_receive :request_code_lens_and_inlay_hints, 900
  end

  test "partial non-headless restore schedules one refresh for the live buffer", %{tmp_dir: dir} do
    existing_path = Path.join(dir, "existing.ex")
    missing_path = Path.join(dir, "missing.ex")
    File.write!(existing_path, "defmodule Existing do\nend\n")

    snapshot = %Snapshot{
      version: 1,
      buffers: [%BufferEntry{file: existing_path}, %BufferEntry{file: missing_path}],
      active_file: missing_path
    }

    assert :ok = Session.save(snapshot, session_dir: dir, project_root: dir)
    %EditorState{} = state = initial_state(dir)

    restored =
      SessionRestore.restore_session(%{state | frontend: %{state.frontend | backend: :tui}})

    assert [_] = TabBar.visible_file_tabs(restored.shell_runtime.state.tab_bar)
    assert Minga.Buffer.file_path(restored.workspace.buffers.active) == existing_path
    assert_receive :request_code_lens_and_inlay_hints, 5_000
    refute_receive :request_code_lens_and_inlay_hints, 900
  end

  test "all-missing non-headless restore schedules no refresh", %{tmp_dir: dir} do
    first_path = Path.join(dir, "first-missing.ex")
    second_path = Path.join(dir, "second-missing.ex")

    snapshot = %Snapshot{
      version: 1,
      buffers: [%BufferEntry{file: first_path}, %BufferEntry{file: second_path}],
      active_file: first_path
    }

    assert :ok = Session.save(snapshot, session_dir: dir, project_root: dir)
    %EditorState{} = state = initial_state(dir)

    restored =
      SessionRestore.restore_session(%{state | frontend: %{state.frontend | backend: :tui}})

    assert [] = TabBar.visible_file_tabs(restored.shell_runtime.state.tab_bar)
    assert restored.shell_runtime.state.tab_bar.active_id == nil
    refute_receive :request_code_lens_and_inlay_hints, 900
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

  test "a buffer with newer unsaved changes keeps them, and the older text stays in its swap", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "edited_since.ex")
    File.write!(path, "saved\n")
    swap_path = Path.join(dir, "edited_since.swap")
    File.write!(swap_path, "the swap file")
    {:ok, buffer} = Minga.Buffer.ensure_for_path(path)
    on_exit(fn -> DynamicSupervisor.terminate_child(Minga.Buffer.Supervisor, buffer) end)
    :ok = Minga.Buffer.replace_content(buffer, "typed since the restart\n")
    state = initial_state(dir)
    entry = %{path: path, swap_path: swap_path, swap_mtime: 0}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert SessionRestore.apply_recovered_entries(state, [
                 {entry, {:ok, path, "from before the crash\n"}}
               ]) == state
      end)

    assert Minga.Buffer.content(buffer) == "typed since the restart\n"
    assert File.exists?(swap_path)
    assert log =~ "#{path} has newer unsaved changes"
    assert log =~ "The unsaved text stays in #{swap_path}"
  end

  test "unsaved text is still recovered when a file the user opened replaced the saved session",
       %{
         tmp_dir: dir
       } do
    path = Path.join(dir, "recovered.ex")
    File.write!(path, "saved\n")
    opened = Path.join(dir, "opened_meanwhile.ex")
    File.write!(opened, "opened\n")
    state = initial_state(dir)
    opts = MingaEditor.Handlers.SessionHandler.project_session_opts(state)

    request =
      MingaEditor.Session.Recovery.request(state, [swap_dir: nil], opts, false, true)

    snapshot = %Snapshot{version: 1, buffers: [%BufferEntry{file: path}], active_file: path}
    entry = %{path: path, swap_path: Path.join(dir, "recovered.swap"), swap_mtime: 0}

    outcome =
      MingaEditor.Effect.Outcome.completed(
        request,
        {:resume,
         %{
           snapshot: snapshot,
           recovered: [{entry, {:ok, path, "unsaved\n"}}],
           held_back: [],
           waiting_elsewhere: 0,
           waiting_projects: []
         }}
      )

    # The user opened a file before the startup read finished.
    {:ok, opened_buffer} = Minga.Buffer.ensure_for_path(opened)
    state = MingaEditor.Handlers.BufferRegistry.register_buffer(state, opened_buffer, opened)

    {resumed, %MingaEditor.Effect.Outcome{value: {:completed, _result}}} =
      MingaEditor.Session.Recovery.apply(state, outcome)

    {:ok, recovered_buffer} = Minga.Buffer.pid_for_path(path)

    on_exit(fn ->
      for buffer <- [opened_buffer, recovered_buffer],
          do: DynamicSupervisor.terminate_child(Minga.Buffer.Supervisor, buffer)
    end)

    # The file the user opened keeps the screen; the unsaved text is there in the background.
    assert resumed.workspace.buffers.active == opened_buffer
    assert recovered_buffer in resumed.workspace.buffers.list
    assert Minga.Buffer.content(recovered_buffer) == "unsaved\n"
    assert Minga.Buffer.dirty?(recovered_buffer)
  end

  describe "the lines a start writes about unsaved text it did not put back" do
    test "say how many files are waiting and name the key that lists them" do
      for {count, line} <- [
            {0, nil},
            {1,
             "Unsaved text of 1 other file is waiting; open its project or the file to recover it, or list it with SPC q u"},
            {3,
             "Unsaved text of 3 other files is waiting; open their project or the files to recover it, or list it with SPC q u"}
          ] do
        assert SessionRestore.waiting_elsewhere_line(count) == line
      end
    end

    test "say which file changed after its text was kept and name the same key" do
      assert SessionRestore.held_back_line("/work/lib/a.ex") ==
               "/work/lib/a.ex changed after its unsaved text was kept, so the text was not put back; " <>
                 "recover or discard it with SPC q u"
    end
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

    assert :ok = Session.save(snapshot, session_dir: dir, project_root: dir)

    restored = dir |> initial_state() |> SessionRestore.restore_session()

    assert [_] = TabBar.visible_file_tabs(restored.shell_runtime.state.tab_bar)
    assert Minga.Buffer.file_path(restored.workspace.buffers.active) == existing_path
    refute File.exists?(missing_path)
    refute_receive :request_code_lens_and_inlay_hints, 20
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
