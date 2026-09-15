defmodule MingaEditor.FilesystemFindFileTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Minga.Config.Options
  alias Minga.Project
  alias Minga.Project.Root
  alias Minga.Project.WorkspaceSnapshot
  alias Minga.Protocol.Opcodes
  alias MingaEditor.Commands.Project, as: ProjectCommands
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.FindFileWorkflow
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.PickerUI
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Interaction
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.DirectorySource
  alias MingaEditor.UI.Picker.FetchEffect
  alias MingaEditor.UI.Picker.FileSource
  alias MingaEditor.UI.Picker.FilesystemCandidate
  alias MingaEditor.UI.Picker.FilesystemContext
  alias MingaEditor.UI.Picker.FilesystemQuery
  alias MingaEditor.UI.Picker.FindFileSession
  alias MingaEditor.UI.Picker.Item

  @op_gui_action Opcodes.gui_action()
  @gui_action_picker_query_changed Opcodes.gui_action_picker_query_changed()
  @gui_action_picker_item_activate Opcodes.gui_action_picker_item_activate()

  test "project finder switches to an absolute directory and restores the captured project source",
       %{
         tmp_dir: tmp_dir
       } do
    project = Path.join(tmp_dir, "project")
    outside = Path.join(tmp_dir, "outside")
    File.mkdir!(project)
    File.mkdir!(outside)
    {:ok, root} = Root.directory(project)
    session = FindFileSession.new(project, tmp_dir, WorkspaceSnapshot.activate(root))
    state = project_picker_state(session)

    switched = PickerUI.replace_query(state, 0, 1, outside <> "/")
    {:picker, %{picker_ui: filesystem}} = switched.shell_runtime.state.modal

    assert filesystem.source == DirectorySource
    assert filesystem.picker.query == outside <> "/"
    assert filesystem.context.query.resolution == {:browse, outside, ""}
    assert filesystem.restore == 0

    restored = PickerUI.replace_query(switched, 0, 2, "readme")
    {:picker, %{picker_ui: project_picker}} = restored.shell_runtime.state.modal

    assert project_picker.source == FileSource
    assert project_picker.picker.query == "readme"
    assert project_picker.context == FindFileSession.project_context(session)
    assert project_picker.restore == 0
  end

  test "filtering a loaded directory reuses its direct children and invalidates the old query", %{
    tmp_dir: tmp_dir
  } do
    alpha = Path.join(tmp_dir, "alpha.txt")
    File.write!(alpha, "alpha")
    File.write!(Path.join(tmp_dir, "beta.txt"), "beta")
    query = directory_query(tmp_dir)
    ready = ready_directory_state(query)
    {:picker, %{picker_ui: before}} = ready.shell_runtime.state.modal
    File.rm!(alpha)

    filtered =
      PickerUI.replace_query(
        ready,
        before.query_generation,
        1,
        Path.join(tmp_dir, "alp")
      )

    {:picker, %{picker_ui: after_edit}} = filtered.shell_runtime.state.modal

    assert after_edit.load_status == :ready
    assert after_edit.fetch_revision == nil
    refute after_edit.context.query.identity == query.identity
    assert [%Item{id: %FilesystemCandidate{path: path}}] = after_edit.picker.filtered
    assert path == alpha
    refute PickerState.current_fetch?(after_edit, before.fetch_revision, query.identity)
  end

  test "folder confirmation stays in one picker and preserves its original restore point", %{
    tmp_dir: tmp_dir
  } do
    nested = Path.join(tmp_dir, "folder with space")
    File.mkdir!(nested)
    File.write!(Path.join(nested, "inside.txt"), "inside")
    ready = ready_directory_state(directory_query(tmp_dir))
    {:picker, %{picker_ui: picker_state}} = ready.shell_runtime.state.modal

    directory =
      Enum.find(picker_state.picker.filtered, &match?(%FilesystemCandidate{path: ^nested}, &1.id))

    selected = select_item(picker_state, directory)
    state = replace_picker_state(ready, selected)

    navigated = PickerUI.handle_key(state, 13, 0)
    assert {:picker, %{picker_ui: next}} = navigated.shell_runtime.state.modal
    assert next.source == DirectorySource
    assert next.restore == picker_state.restore

    assert next.picker.query ==
             FilesystemQuery.for_directory(picker_state.context.query.session, nested).text

    assert next.context.query.resolution == {:browse, nested, ""}

    typed = PickerUI.handle_key(navigated, ?i, 0)
    assert picker_state(typed).picker.query == next.picker.query <> "i"

    backed_up = PickerUI.handle_key(navigated, 127, 0)

    assert picker_state(backed_up).context.query.resolution ==
             {:browse, tmp_dir, "folder with space"}
  end

  test "native query and semantic activation open the exact Unicode file outside a different project",
       %{
         tmp_dir: tmp_dir
       } do
    project = Path.join(tmp_dir, "project")
    outside = Path.join(tmp_dir, "outside")
    File.mkdir!(project)
    File.mkdir!(outside)
    path = Path.join(outside, "résumé file.txt")
    File.write!(path, "opened through native actions")
    {:ok, root} = Root.directory(project)
    session = FindFileSession.new(project, tmp_dir, WorkspaceSnapshot.activate(root))
    state = project_picker_state(session)

    query_packet =
      <<@op_gui_action, @gui_action_picker_query_changed, 0::32, 1::32, byte_size(path)::16,
        path::binary>>

    assert {:ok, {:gui_action, query_action}} = Protocol.decode_event(query_packet)
    loading = GuiActionHandler.dispatch(state, query_action)
    ready = complete_current_fetch(loading)
    {:picker, %{picker_ui: picker_state}} = ready.shell_runtime.state.modal
    assert [%Item{id: %FilesystemCandidate{path: ^path}}] = picker_state.picker.filtered

    generation = picker_state.activation_offer.generation
    activation_id = picker_state.activation_offer.items |> hd() |> elem(0)

    activation_packet =
      <<@op_gui_action, @gui_action_picker_item_activate, generation::32, activation_id::32>>

    assert {:ok, {:gui_action, activation_action}} = Protocol.decode_event(activation_packet)
    opened = GuiActionHandler.dispatch(ready, activation_action)
    on_exit(fn -> stop_added_buffers(opened, state) end)

    assert opened.shell_runtime.state.modal == :none
    assert Minga.Buffer.file_path(opened.workspace.buffers.active) == path
  end

  test "a disappeared selected file keeps the query open and reports the exact failure", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "vanishes.txt")
    File.write!(path, "temporary")
    ready = ready_directory_state(FilesystemQuery.parse(session(tmp_dir), path))
    {:picker, %{picker_ui: picker_state}} = ready.shell_runtime.state.modal
    File.rm!(path)

    failed = PickerUI.handle_key(ready, 13, 0)

    assert {:picker, %{picker_ui: after_failure}} = failed.shell_runtime.state.modal
    assert after_failure.picker.query == path
    assert {:error, message} = after_failure.load_status
    assert message =~ "does not exist"
    assert failed.shell_runtime.state.notice.message == message
    assert picker_state.restore == after_failure.restore
  end

  test "a selected entry that changes into a directory is not opened as a file", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "changes-kind.txt")
    File.write!(path, "temporary")
    ready = ready_directory_state(FilesystemQuery.parse(session(tmp_dir), path))
    File.rm!(path)
    File.mkdir!(path)

    failed = PickerUI.handle_key(ready, 13, 0)

    assert {:picker, %{picker_ui: after_failure}} = failed.shell_runtime.state.modal
    assert after_failure.picker.query == path
    assert {:error, message} = after_failure.load_status
    assert message =~ "directory"
    assert failed.workspace.buffers.list == ready.workspace.buffers.list
  end

  test "an unreadable selected file keeps the picker and exact query", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "unreadable.txt")
    File.write!(path, "private")
    ready = ready_directory_state(FilesystemQuery.parse(session(tmp_dir), path))
    File.chmod!(path, 0o000)
    on_exit(fn -> File.chmod(path, 0o600) end)

    failed = PickerUI.handle_key(ready, 13, 0)

    assert {:picker, %{picker_ui: after_failure}} = failed.shell_runtime.state.modal
    assert after_failure.picker.query == path
    assert {:error, message} = after_failure.load_status
    assert message =~ "eacces" or message =~ "readable"
    assert failed.workspace.buffers.list == ready.workspace.buffers.list
  end

  test "a rejected binary file keeps the picker and does not register a buffer", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "binary.dat")
    File.write!(path, <<255, 254, 253>>)
    ready = ready_directory_state(FilesystemQuery.parse(session(tmp_dir), path))

    failed = PickerUI.handle_key(ready, 13, 0)

    assert {:picker, %{picker_ui: after_failure}} = failed.shell_runtime.state.modal
    assert after_failure.picker.query == path
    assert {:error, message} = after_failure.load_status
    assert message =~ "binary_file"
    assert Minga.Buffer.pid_for_path(path) == :not_found
  end

  test "target-first filesystem opens deduplicate a later symlink without project side effects",
       %{
         tmp_dir: tmp_dir
       } do
    assert_filesystem_symlink_dedup(tmp_dir, :target_first)
  end

  test "alias-first filesystem opens canonicalize before duplicate lookup without project side effects",
       %{
         tmp_dir: tmp_dir
       } do
    assert_filesystem_symlink_dedup(tmp_dir, :alias_first)
  end

  test "an oversized exact target uses the production refusal surface without opening file bytes",
       %{
         tmp_dir: tmp_dir
       } do
    options_server =
      start_supervised!(
        {Options, name: :"filesystem_find_opts_#{System.unique_integer([:positive])}"}
      )

    Options.set(options_server, :max_file_size, 8)
    path = Path.join(tmp_dir, "oversized.txt")
    File.write!(path, "these bytes must not enter a file buffer")

    initial = TestHelpers.base_state(content: "initial")
    state = %{initial | interaction: Interaction.new(options_server: options_server)}
    opened = state |> ready_for_file(path, tmp_dir) |> PickerUI.handle_key(13, 0)
    on_exit(fn -> stop_added_buffers(opened, initial) end)

    assert opened.shell_runtime.state.modal == :none
    assert Minga.Buffer.file_path(opened.workspace.buffers.active) == nil
    assert Minga.Buffer.content(opened.workspace.buffers.active) =~ "File too large for Minga V1"
    assert Minga.Buffer.pid_for_path(path) == :not_found
  end

  test "an older directory result cannot replace a newer query even when it completes last", %{
    tmp_dir: tmp_dir
  } do
    first_dir = Path.join(tmp_dir, "first")
    second_dir = Path.join(tmp_dir, "second")
    File.mkdir!(first_dir)
    File.mkdir!(second_dir)
    File.write!(Path.join(first_dir, "old.txt"), "old")
    File.write!(Path.join(second_dir, "new.txt"), "new")
    first_query = FilesystemQuery.for_directory(session(tmp_dir), first_dir)
    {first_loading, first_request} = loading_directory_state(first_query)
    {:ok, first_result} = FetchEffect.run(first_request.effect)

    second_loading =
      PickerUI.replace_query(
        first_loading,
        picker_state(first_loading).query_generation,
        1,
        second_dir <> "/"
      )

    second_ready = complete_current_fetch(second_loading)
    first_outcome = Outcome.completed(first_request, first_result)

    assert {^second_ready, %Outcome{value: {:stale, :picker_closed_or_replaced}}} =
             FetchEffect.apply(second_ready, first_outcome)

    {:picker, %{picker_ui: current}} = second_ready.shell_runtime.state.modal
    assert contains_path?(current.picker.items, Path.join(second_dir, "new.txt"))
    refute contains_path?(current.picker.items, Path.join(first_dir, "old.txt"))
  end

  test "a project result captured before another activation is rejected before publication", %{
    tmp_dir: tmp_dir
  } do
    original_workspace = Project.snapshot()
    project_a = Path.join(tmp_dir, "project-a")
    project_b = Path.join(tmp_dir, "project-b")
    File.mkdir!(project_a)
    File.mkdir!(project_b)
    File.write!(Path.join(project_a, "a.txt"), "A")
    File.write!(Path.join(project_b, "b.txt"), "B")
    {:ok, root_a} = Root.directory(project_a)
    {:ok, root_b} = Root.directory(project_b)
    snapshot_a = activate_project!(root_a)
    on_exit(fn -> restore_project(original_workspace) end)

    session = FindFileSession.new(project_a, tmp_dir, snapshot_a)
    {loading, request} = loading_project_state(session)
    {:ok, result} = FetchEffect.run(request.effect)
    snapshot_b = activate_project!(root_b)
    outcome = Outcome.completed(request, result)

    assert snapshot_b.activation_id != snapshot_a.activation_id

    assert {^loading, %Outcome{value: {:stale, :picker_closed_or_replaced}}} =
             FetchEffect.apply(loading, outcome)

    assert picker_state(loading).picker.items == []
  end

  test "an installed project candidate is rejected after another workspace activates", %{
    tmp_dir: tmp_dir
  } do
    original_workspace = Project.snapshot()
    project_a = Path.join(tmp_dir, "project-a")
    project_b = Path.join(tmp_dir, "project-b")
    File.mkdir!(project_a)
    File.mkdir!(project_b)
    path_a = Path.join(project_a, "a.txt")
    File.write!(path_a, "A")
    File.write!(Path.join(project_b, "b.txt"), "B")
    {:ok, root_a} = Root.directory(project_a)
    {:ok, root_b} = Root.directory(project_b)
    snapshot_a = activate_project!(root_a)
    on_exit(fn -> restore_project(original_workspace) end)

    session = FindFileSession.new(project_a, tmp_dir, snapshot_a)
    {loading, request} = loading_project_state(session)
    {:ok, result} = FetchEffect.run(request.effect)
    {ready, _outcome} = FetchEffect.apply(loading, Outcome.completed(request, result))

    assert [%Item{id: %MingaEditor.UI.Picker.ProjectFileCandidate{activation_id: activation_id}}] =
             picker_state(ready).picker.items

    assert activation_id == snapshot_a.activation_id
    _snapshot_b = activate_project!(root_b)
    rejected = PickerUI.handle_key(ready, 13, 0)

    assert {:picker, %{picker_ui: rejected_picker}} = rejected.shell_runtime.state.modal
    assert rejected_picker.picker.query == ""
    assert rejected.shell_runtime.state.notice.message =~ "Project changed"
    assert rejected.workspace.buffers.list == ready.workspace.buffers.list
    assert Minga.Buffer.pid_for_path(path_a) == :not_found
  end

  test "projectless workflow starts at captured cwd even when the file tree was never opened", %{
    tmp_dir: tmp_dir
  } do
    original_workspace = Project.snapshot()
    previous_cwd = File.cwd!()
    Project.close()
    _ = :sys.get_state(Project)
    File.cd!(tmp_dir)

    on_exit(fn ->
      File.cd!(previous_cwd)
      restore_project(original_workspace)
    end)

    state = FindFileWorkflow.open(TestHelpers.base_state(content: "initial"))
    assert {:picker, %{picker_ui: picker_state}} = state.shell_runtime.state.modal
    assert picker_state.source == DirectorySource
    assert picker_state.context.query.resolution == {:browse, tmp_dir, ""}

    expected_session = FindFileSession.new(tmp_dir, Path.expand("~"), nil)

    assert picker_state.picker.query ==
             FilesystemQuery.for_directory(expected_session, tmp_dir).text
  end

  test "general and project-specific finders keep distinct project source contexts", %{
    tmp_dir: tmp_dir
  } do
    original_workspace = Project.snapshot()
    project = Path.join(tmp_dir, "project")
    File.mkdir!(project)
    {:ok, root} = Root.directory(project)
    assert {:ok, _snapshot} = Project.activate(root)

    on_exit(fn -> restore_project(original_workspace) end)

    general = FindFileWorkflow.open(TestHelpers.base_state(content: "general"))
    assert picker_state(general).source == FileSource
    assert picker_state(general).context.project_root == root
    assert %FindFileSession{project_root: ^root} = picker_state(general).context.find_file_session

    project_only =
      ProjectCommands.execute(TestHelpers.base_state(content: "project"), :project_find_file)

    assert picker_state(project_only).source == FileSource
    assert picker_state(project_only).context == nil
  end

  @spec project_picker_state(FindFileSession.t()) :: MingaEditor.State.t()
  defp project_picker_state(session) do
    picker = Picker.new([%Item{id: :project, label: "README.md"}], title: "Find file")

    picker_state = %PickerState{
      picker: picker,
      source: FileSource,
      restore: 0,
      context: FindFileSession.project_context(session)
    }

    TestHelpers.base_state(content: "initial")
    |> ModalWorkflow.open({:picker, PickerPayload.new(picker_state)})
  end

  @spec directory_query(String.t()) :: FilesystemQuery.t()
  defp directory_query(directory),
    do: FilesystemQuery.for_directory(session(directory), directory)

  @spec session(String.t()) :: FindFileSession.t()
  defp session(directory), do: FindFileSession.new(directory, directory, nil)

  @spec ready_directory_state(FilesystemQuery.t()) :: MingaEditor.State.t()
  defp ready_directory_state(query) do
    {loading, request} = loading_directory_state(query)
    {:ok, result} = FetchEffect.run(request.effect)
    {ready, _outcome} = FetchEffect.apply(loading, Outcome.completed(request, result))
    ready
  end

  @spec ready_for_file(MingaEditor.State.t(), String.t(), String.t()) :: MingaEditor.State.t()
  defp ready_for_file(state, path, launch_directory) do
    query = FilesystemQuery.parse(session(launch_directory), path)
    {loading, request} = loading_directory_state(state, query)
    {:ok, result} = FetchEffect.run(request.effect)
    {ready, _outcome} = FetchEffect.apply(loading, Outcome.completed(request, result))
    ready
  end

  @spec loading_directory_state(FilesystemQuery.t()) ::
          {MingaEditor.State.t(), MingaEditor.Effect.Request.t()}
  defp loading_directory_state(query) do
    loading_directory_state(TestHelpers.base_state(content: "initial"), query)
  end

  @spec loading_directory_state(MingaEditor.State.t(), FilesystemQuery.t()) ::
          {MingaEditor.State.t(), MingaEditor.Effect.Request.t()}
  defp loading_directory_state(state, query) do
    context = FilesystemContext.new(query)
    {loading, revision} = PickerUI.open_loading(state, DirectorySource, context)
    picker_state = picker_state(loading)

    request =
      FetchEffect.request(
        DirectorySource,
        picker_state.callback_source,
        Context.from_editor_state(loading),
        revision
      )

    {loading, request}
  end

  @spec loading_project_state(FindFileSession.t()) ::
          {MingaEditor.State.t(), MingaEditor.Effect.Request.t()}
  defp loading_project_state(session) do
    context = FindFileSession.project_context(session)

    {loading, revision} =
      PickerUI.open_loading(TestHelpers.base_state(content: "initial"), FileSource, context)

    current = picker_state(loading)

    request =
      FetchEffect.request(
        FileSource,
        current.callback_source,
        Context.from_editor_state(loading),
        revision
      )

    {loading, request}
  end

  @spec complete_current_fetch(MingaEditor.State.t()) :: MingaEditor.State.t()
  defp complete_current_fetch(state) do
    current = picker_state(state)

    request =
      FetchEffect.request(
        current.source,
        current.callback_source,
        Context.from_editor_state(state),
        current.fetch_revision
      )

    {:ok, result} = FetchEffect.run(request.effect)
    {ready, _outcome} = FetchEffect.apply(state, Outcome.completed(request, result))
    ready
  end

  @spec picker_state(MingaEditor.State.t()) :: PickerState.t()
  defp picker_state(%{shell_runtime: %{state: %{modal: {:picker, payload}}}}),
    do: payload.picker_ui

  @spec select_item(PickerState.t(), Item.t()) :: PickerState.t()
  defp select_item(picker_state, item) do
    index = Enum.find_index(picker_state.picker.filtered, &(&1.id == item.id))
    picker = Picker.select_index(picker_state.picker, index)
    PickerState.update_picker(picker_state, picker)
  end

  @spec replace_picker_state(MingaEditor.State.t(), PickerState.t()) :: MingaEditor.State.t()
  defp replace_picker_state(state, picker_state) do
    PickerUI.update_picker(state, fn _current -> picker_state end)
  end

  @spec stop_added_buffers(MingaEditor.State.t(), MingaEditor.State.t()) :: :ok
  defp stop_added_buffers(after_state, before_state) do
    existing = MapSet.new(before_state.workspace.buffers.list)

    after_state.workspace.buffers.list
    |> Enum.reject(&MapSet.member?(existing, &1))
    |> Enum.each(&GenServer.stop/1)
  end

  @spec contains_path?([Item.t()], String.t()) :: boolean()
  defp contains_path?(items, expected_path) do
    Enum.any?(items, fn
      %Item{id: %FilesystemCandidate{path: path}} -> path == expected_path
      %Item{} -> false
    end)
  end

  @spec assert_filesystem_symlink_dedup(String.t(), :target_first | :alias_first) :: :ok
  defp assert_filesystem_symlink_dedup(tmp_dir, order) do
    original_workspace = Project.snapshot()
    known_projects = Project.known_projects()
    Project.close()
    _ = :sys.get_state(Project)
    on_exit(fn -> restore_project(original_workspace) end)

    target = Path.join(tmp_dir, "canonical.txt")
    alias_path = Path.join(tmp_dir, "canonical-link.txt")
    File.write!(target, "canonical")
    File.ln_s!(target, alias_path)
    initial = TestHelpers.base_state(content: "initial")
    {first_path, second_path} = symlink_open_order(order, target, alias_path)

    first = initial |> ready_for_file(first_path, tmp_dir) |> PickerUI.handle_key(13, 0)
    first_pid = first.workspace.buffers.active
    first_count = length(first.workspace.buffers.list)
    second = first |> ready_for_file(second_path, tmp_dir) |> PickerUI.handle_key(13, 0)
    on_exit(fn -> stop_added_buffers(second, initial) end)

    assert second.workspace.buffers.active == first_pid
    assert length(second.workspace.buffers.list) == first_count
    assert Minga.Buffer.content(first_pid) == "canonical"
    assert Minga.Buffer.file_path(first_pid) == target
    assert Project.snapshot() == nil
    assert Project.known_projects() == known_projects
    assert second.workspace.file_tree == initial.workspace.file_tree
    :ok
  end

  @spec symlink_open_order(:target_first | :alias_first, String.t(), String.t()) ::
          {String.t(), String.t()}
  defp symlink_open_order(:target_first, target, alias_path), do: {target, alias_path}
  defp symlink_open_order(:alias_first, target, alias_path), do: {alias_path, target}

  @spec activate_project!(Root.t()) :: WorkspaceSnapshot.t()
  defp activate_project!(%Root{path: path} = root) do
    Minga.Events.subscribe(:project_rebuilt)
    assert {:ok, snapshot} = Project.activate(root)

    if snapshot.rebuilding? do
      assert_receive {:minga_event, :project_rebuilt,
                      %Minga.Events.ProjectRebuiltEvent{root: ^path}},
                     5_000
    end

    _ = :sys.get_state(Project)
    Project.snapshot()
  end

  @spec restore_project(WorkspaceSnapshot.t() | nil) :: :ok
  defp restore_project(nil) do
    Project.close()
    _ = :sys.get_state(Project)
    :ok
  end

  defp restore_project(%WorkspaceSnapshot{root: root}) do
    Project.close()
    _ = :sys.get_state(Project)
    _ = Project.activate(root)
    :ok
  end
end
