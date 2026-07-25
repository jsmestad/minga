defmodule MingaEditor.Handlers.BufferRegistryNavigationTest do
  use ExUnit.Case, async: false

  import MingaEditor.RenderPipeline.TestHelpers, only: [base_state: 1]

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Handlers.BufferRegistry
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar

  @moduletag :tmp_dir

  test "opens a missing live buffer for an existing filesystem path", %{tmp_dir: tmp_dir} do
    path = write_file!(tmp_dir, "opened.txt")
    state = base_state(content: "scratch")

    assert {:ok, new_state, pid, :opened} = BufferRegistry.open_or_activate_path(state, path)
    assert pid in new_state.workspace.buffers.list
    assert new_state.workspace.buffers.active == pid
    assert Buffer.file_path(pid) == path
  end

  test "activates an already-live path without starting another buffer", %{tmp_dir: tmp_dir} do
    first_path = write_file!(tmp_dir, "first.txt")
    second_path = write_file!(tmp_dir, "second.txt")
    first = file_buffer!(first_path)
    second = file_buffer!(second_path)
    state = state_with_buffers([first, second], 1)

    assert {:ok, new_state, ^first, :activated} =
             BufferRegistry.open_or_activate_path(state, first_path)

    assert new_state.workspace.buffers.list == [first, second]
    assert new_state.workspace.buffers.active == first
    assert new_state.workspace.buffers.active_index == 0
  end

  test "switches to an existing tab when requested and a tab exists", %{tmp_dir: tmp_dir} do
    target_path = write_file!(tmp_dir, "target.txt")
    active_path = write_file!(tmp_dir, "active.txt")
    target = file_buffer!(target_path)
    active = file_buffer!(active_path)

    state =
      [target, active]
      |> state_with_buffers(1)
      |> with_target_tab(target, "target.txt")

    assert {:ok, new_state, ^target, :switched_tab} =
             BufferRegistry.open_or_activate_path(state, target_path, existing_target: :tab)

    assert new_state.workspace.buffers.active == target
    assert TabBar.active(new_state.shell_runtime.state.tab_bar).id == 2
  end

  test "falls back to buffer activation when tab preference has no matching tab", %{
    tmp_dir: tmp_dir
  } do
    target_path = write_file!(tmp_dir, "target-without-tab.txt")
    active_path = write_file!(tmp_dir, "active-without-tab.txt")
    target = file_buffer!(target_path)
    active = file_buffer!(active_path)
    state = state_with_buffers([target, active], 1)

    assert {:ok, new_state, ^target, :activated} =
             BufferRegistry.open_or_activate_path(state, target_path, existing_target: :tab)

    assert new_state.workspace.buffers.active == target
    assert new_state.workspace.buffers.active_index == 0
  end

  test "returns a start error without mutating buffers", %{tmp_dir: tmp_dir} do
    missing_path = Path.join(tmp_dir, "missing.txt") |> Path.expand()
    state = base_state(content: "scratch")
    original_buffers = state.workspace.buffers.list
    original_active = state.workspace.buffers.active

    assert {:error, :enoent} = BufferRegistry.open_or_activate_path(state, missing_path)
    assert state.workspace.buffers.list == original_buffers
    assert state.workspace.buffers.active == original_active
  end

  test "rejects unknown open-or-activate option keys", %{tmp_dir: tmp_dir} do
    path = write_file!(tmp_dir, "invalid-key.txt")
    state = base_state(content: "scratch")
    original_active = state.workspace.buffers.active
    original_buffers = state.workspace.buffers.list

    assert {:error, {:invalid_option, :existng_target}} =
             BufferRegistry.open_or_activate_path(state, path, existng_target: :tab)

    assert state.workspace.buffers.active == original_active
    assert state.workspace.buffers.list == original_buffers
  end

  test "rejects invalid existing-target policy values", %{tmp_dir: tmp_dir} do
    path = write_file!(tmp_dir, "invalid-target.txt")
    state = base_state(content: "scratch")
    original_active = state.workspace.buffers.active
    original_buffers = state.workspace.buffers.list

    assert {:error, {:invalid_option, :existing_target}} =
             BufferRegistry.open_or_activate_path(state, path, existing_target: :tabs)

    assert state.workspace.buffers.active == original_active
    assert state.workspace.buffers.list == original_buffers
  end

  test "rejects invalid options-server and start option values", %{tmp_dir: tmp_dir} do
    path = write_file!(tmp_dir, "invalid-values.txt")
    state = base_state(content: "scratch")
    original_active = state.workspace.buffers.active
    original_buffers = state.workspace.buffers.list

    assert {:error, {:invalid_option, :options_server}} =
             BufferRegistry.open_or_activate_path(state, path, options_server: {:bad, :name})

    assert {:error, {:invalid_option, :start_opts}} =
             BufferRegistry.open_or_activate_path(state, path, start_opts: :not_options)

    assert {:error, {:invalid_option, :start_opts}} =
             BufferRegistry.open_or_activate_path(state, path, start_opts: [:bad])

    assert {:error, {:invalid_options, :not_a_keyword_list}} =
             BufferRegistry.open_or_activate_path(state, path, [:not_a_keyword])

    assert state.workspace.buffers.active == original_active
    assert state.workspace.buffers.list == original_buffers
  end

  defp write_file!(tmp_dir, name) do
    path = Path.join(tmp_dir, name) |> Path.expand()
    File.write!(path, name)
    path
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
      Tab.new_file(1, "active.txt") |> Tab.set_context(TabContext.from_workspace(state.workspace))

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
end
