defmodule MingaGitPorcelain.UI.Picker.GitChangedSourceTest do
  use ExUnit.Case, async: false

  unless Code.ensure_loaded?(MingaGitPorcelain.UI.Picker.GitChangedSource) do
    Code.require_file(
      "../../../../lib/minga_git_porcelain/ui/picker/git_changed_source.ex",
      __DIR__
    )
  end

  import MingaEditor.RenderPipeline.TestHelpers, only: [base_state: 1]

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Project
  alias Minga.Project.Root
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.UI.Picker.Item
  alias MingaGitPorcelain.UI.Picker.GitChangedSource

  @moduletag :tmp_dir

  setup do
    original_workspace = Project.snapshot()
    on_exit(fn -> restore_project(original_workspace) end)
    :ok
  end

  test "selecting an already-open changed file switches to its tab", %{tmp_dir: tmp_dir} do
    rel_path = "lib/changed.ex"
    target_path = Path.join(tmp_dir, rel_path)
    active_path = Path.join(tmp_dir, "lib/active.ex")
    File.mkdir_p!(Path.dirname(target_path))
    File.write!(target_path, "changed")
    File.write!(active_path, "active")
    {:ok, root} = Root.directory(tmp_dir)
    {:ok, _snapshot} = Project.activate(root)

    target = file_buffer!(target_path)
    active = file_buffer!(active_path)

    state =
      [target, active]
      |> state_with_buffers(1)
      |> with_target_tab(target, "changed.ex")

    selected = GitChangedSource.on_select(%Item{id: rel_path, label: "changed.ex"}, state)

    assert selected.workspace.buffers.active == target
    assert TabBar.active(selected.shell_runtime.state.tab_bar).id == 2
  end

  defp file_buffer!(path) do
    {:ok, pid} = BufferProcess.start_link(file_path: path)
    pid
  end

  defp state_with_buffers(buffers, active_index) do
    state = base_state(content: "scratch")
    active = Enum.at(buffers, active_index)
    buffer_state = %Buffers{active: active, list: buffers, active_index: active_index}
    %{state | workspace: SessionState.set_buffers(state.workspace, buffer_state)}
  end

  defp with_target_tab(state, target, label) do
    active_tab =
      Tab.new_file(1, "active.ex") |> Tab.set_context(TabContext.from_workspace(state.workspace))

    target_workspace =
      SessionState.set_buffers(state.workspace, %Buffers{
        active: target,
        list: [target],
        active_index: 0
      })

    target_tab =
      Tab.new_file(2, label) |> Tab.set_context(TabContext.from_workspace(target_workspace))

    tab_bar = %TabBar{tabs: [active_tab, target_tab], active_id: 1, next_id: 3}
    shell_state = ShellState.install_tab_bar(state.shell_runtime.state, tab_bar)
    %{state | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)}
  end

  defp restore_project(nil), do: Project.close()
  defp restore_project(%Minga.Project.WorkspaceSnapshot{root: root}), do: Project.activate(root)
end
