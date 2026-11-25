defmodule MingaEditor.Extension.GitStatusTest do
  # Exercises the production sidebar registry and active project.
  use ExUnit.Case, async: false

  alias Minga.Buffer
  alias Minga.Extension.CodeLease
  alias Minga.Extension.Instance.Artifact
  alias Minga.Extension.Instance.Contributions
  alias Minga.Extension.InvocationContext
  alias Minga.Extension.Manifest
  alias Minga.Git.Repo
  alias Minga.Git.Stub
  alias Minga.Project
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Extension.GitStatus
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Extension.SourceFinalizer
  alias MingaEditor.GitStatus.Panel
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias MingaEditor.State.FileTree

  @moduletag :tmp_dir

  defmodule StatusProvider do
    use Minga.Extension

    @impl true
    def name, do: :native_git_status_test

    @impl true
    def description, do: "Provides the native Git Status test surface"

    @impl true
    def version, do: "0.1.0"

    @impl true
    def init(_config) do
      with :ok <- GitStatus.register(), do: {:ok, %{}}
    end
  end

  setup do
    name = StatusProvider.name()
    source = {:extension, name}
    previous_workspace = Project.workspace_root()
    manifest = Manifest.from_module(StatusProvider, :module)
    {:ok, artifact} = Artifact.build(name, StatusProvider, manifest, [StatusProvider], [])

    on_exit(fn ->
      case CodeLease.quiesce_source(source) do
        {:ok, token} -> CodeLease.complete_unload(token)
        _ -> :ok
      end

      :ok = Contributions.cleanup(name, [])
      if previous_workspace, do: Project.switch(previous_workspace), else: Project.close()
      _ = Project.root()
    end)

    %{name: name, source: source, artifact: artifact}
  end

  test "only the active registration can show the native surface across unload and reload", ctx do
    task_supervisor = start_supervised!(Task.Supervisor)
    scheduler = start_supervised!({EffectScheduler, task_supervisor: task_supervisor})
    :ok = EffectScheduler.attach(scheduler, self())

    state =
      TestHelpers.base_state(
        sidebar_registry: Sidebar.default_table(),
        effect_scheduler: scheduler
      )

    assert {:error, :not_extension_callback} = GitStatus.register()
    assert GitStatus.toggle(state) == state

    assert :ok = Contributions.prepare_runtime(ctx.name, ctx.artifact, [], [])

    assert %{source: source, visible?: false, semantic_kind: "git_status"} =
             Sidebar.get("git_status")

    assert source == ctx.source
    assert GitStatus.toggle(state) == state
    assert {unavailable, :repo_unavailable} = GitStatus.prepare_commit(state)
    assert NoticeWorkflow.message(unavailable) == "Git Status is not available"

    assert {:error, {:duplicate_sidebar_id, "git_status", ^source}} =
             InvocationContext.with_source({:extension, :other_provider}, &GitStatus.register/0)

    assert :ok = CodeLease.activate_source(ctx.source, [StatusProvider])
    :ok = Project.close()

    assert {shown, :not_git} = GitStatus.prepare_commit(state)
    assert %Panel{id: id, repo_state: :not_a_repo} = SidebarWorkflow.git_status_panel(shown)
    assert id > 0
    assert SidebarWorkflow.active_id(shown) == "git_status"
    assert %{source: ^source, visible?: true} = Sidebar.get("git_status")

    assert {:ok, token} = CodeLease.quiesce_source(source)
    assert GitStatus.toggle(shown) == shown
    assert {:ok, ^shown} = SourceFinalizer.finalize(shown, {:extension, :other_provider})
    assert {:ok, closed} = SourceFinalizer.finalize(shown, source)
    assert SidebarWorkflow.git_status_panel(closed) == nil
    assert SidebarWorkflow.active_id(closed) == nil
    assert closed.workspace.keymap_scope == :editor

    assert :ok = CodeLease.complete_unload(token)
    assert :ok = Contributions.cleanup(ctx.name, [])
    assert Sidebar.get("git_status") == nil
    assert GitStatus.toggle(closed) == closed

    assert :ok = Contributions.prepare_runtime(ctx.name, ctx.artifact, [], [])
    assert :ok = CodeLease.activate_source(ctx.source, [StatusProvider])
    reopened = GitStatus.toggle(closed)

    assert %Panel{id: reopened_id, repo_state: :not_a_repo} =
             SidebarWorkflow.git_status_panel(reopened)

    assert reopened_id > 0 and reopened_id != id
    reclosed = GitStatus.toggle(reopened)
    assert SidebarWorkflow.git_status_panel(reclosed) == nil
    assert %{source: ^source, visible?: false} = Sidebar.get("git_status")
  end

  test "commit preparation reports a resolved repository without a running service", ctx do
    file_path = Path.join(ctx.tmp_dir, "current.txt")
    File.write!(file_path, "tracked text\n")
    :ok = Stub.set_root(file_path, ctx.tmp_dir)
    on_exit(fn -> Stub.clear(file_path) end)

    assert :ok = Contributions.prepare_runtime(ctx.name, ctx.artifact, [], [])
    assert :ok = CodeLease.activate_source(ctx.source, [StatusProvider])
    state = TestHelpers.base_state(sidebar_registry: Sidebar.default_table())
    :ok = Buffer.open(state.workspace.buffers.active, file_path)

    assert {unavailable, :repo_unavailable} = GitStatus.prepare_commit(state)
    assert NoticeWorkflow.message(unavailable) == "Git.Repo not available"
    assert SidebarWorkflow.git_status_panel(unavailable) == nil
  end

  test "commit preparation uses the loaded panel, not the current project or entry base", ctx do
    nested_project = Path.join(ctx.tmp_dir, "repo/apps/current")
    repo_root = Path.join(ctx.tmp_dir, "repo")
    other_project = Path.join(ctx.tmp_dir, "other")
    File.mkdir_p!(nested_project)
    File.mkdir_p!(other_project)
    :ok = Stub.set_root(nested_project, repo_root)
    :ok = Stub.set_last_commit_message(repo_root, "previous commit")

    on_exit(fn ->
      Stub.clear(nested_project)
      Stub.clear(repo_root)
    end)

    repo = start_supervised!({Repo, git_root: repo_root, project_root: nested_project})
    :ok = Repo.await_refresh(repo)
    :ok = Project.switch(nested_project)

    assert :ok = Contributions.prepare_runtime(ctx.name, ctx.artifact, [], [])
    assert :ok = CodeLease.activate_source(ctx.source, [StatusProvider])

    state = TestHelpers.base_state(sidebar_registry: Sidebar.default_table())
    tree = FileTree.set_project_root(state.workspace.file_tree, nested_project)
    state = %{state | workspace: SessionState.set_file_tree(state.workspace, tree)}
    opened = GitStatus.toggle(state)

    assert %Panel{git_root: ^repo_root, entry_base_path: ^nested_project} =
             SidebarWorkflow.git_status_panel(opened)

    :ok = Project.switch(other_project)
    other_sidebar = SidebarWorkflow.open_observatory(opened, nil)

    assert {focused, {:ok, ^repo_root, "previous commit"}} =
             GitStatus.prepare_commit(other_sidebar)

    assert SidebarWorkflow.active_id(focused) == "git_status"
  end

  test "a file-only workspace opens status and accepts file navigation keys", ctx do
    file_path = Path.join(ctx.tmp_dir, "current.txt")
    File.write!(file_path, "tracked text\n")
    :ok = Stub.set_root(file_path, ctx.tmp_dir)
    entry = %Minga.Git.StatusEntry{path: "current.txt", status: :modified, staged: false}
    :ok = Stub.set_status(ctx.tmp_dir, [entry])

    on_exit(fn ->
      Stub.clear(file_path)
      Stub.clear(ctx.tmp_dir)
    end)

    repo = start_supervised!({Repo, git_root: ctx.tmp_dir})
    :ok = Repo.await_refresh(repo)
    :ok = Contributions.prepare_runtime(ctx.name, ctx.artifact, [], [])
    :ok = CodeLease.activate_source(ctx.source, [StatusProvider])

    state = TestHelpers.base_state(sidebar_registry: Sidebar.default_table())
    :ok = Buffer.open(state.workspace.buffers.active, file_path)
    git_root = ctx.tmp_dir

    opened = GitStatus.toggle(state)

    assert %Panel{git_root: ^git_root, repo_state: :normal, entries: [^entry]} =
             SidebarWorkflow.git_status_panel(opened)

    navigated = MingaEditor.Input.Router.route_key(opened, ?j, 0)
    status = SidebarWorkflow.git_status_tui_state(navigated)
    assert MingaEditor.GitStatus.TUIState.selected_file(status, [entry]) == entry
  end

  test "a clean tree moves through its next steps with j and k", ctx do
    file_path = Path.join(ctx.tmp_dir, "clean.txt")
    File.write!(file_path, "committed text\n")
    :ok = Stub.set_root(file_path, ctx.tmp_dir)
    :ok = Stub.set_status(ctx.tmp_dir, [])

    on_exit(fn ->
      Stub.clear(file_path)
      Stub.clear(ctx.tmp_dir)
    end)

    repo = start_supervised!({Repo, git_root: ctx.tmp_dir})
    :ok = Repo.await_refresh(repo)
    :ok = Contributions.prepare_runtime(ctx.name, ctx.artifact, [], [])
    :ok = CodeLease.activate_source(ctx.source, [StatusProvider])

    state = TestHelpers.base_state(sidebar_registry: Sidebar.default_table())
    :ok = Buffer.open(state.workspace.buffers.active, file_path)
    opened = GitStatus.toggle(state)
    assert %Panel{repo_state: :normal, entries: []} = SidebarWorkflow.git_status_panel(opened)

    down = MingaEditor.Input.Router.route_key(opened, ?j, 0)
    assert SidebarWorkflow.git_status_tui_state(down).cursor_index == 1

    # The cursor stays on the last step instead of running past it.
    still = MingaEditor.Input.Router.route_key(down, ?j, 0)
    assert SidebarWorkflow.git_status_tui_state(still).cursor_index == 1

    up = MingaEditor.Input.Router.route_key(still, ?k, 0)
    assert SidebarWorkflow.git_status_tui_state(up).cursor_index == 0

    # Enter runs the highlighted step and `o` only opens files; both resolve through the panel's keys.
    assert {:command, :git_status_activate} =
             Minga.Keymap.Scope.resolve_key(:git_status, :normal, {13, 0})

    assert {:command, :git_status_open_file} =
             Minga.Keymap.Scope.resolve_key(:git_status, :normal, {?o, 0})
  end
end
