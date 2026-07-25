defmodule MingaEditor.UI.Picker.WorkspaceSymbolSourceTest do
  use ExUnit.Case, async: true

  import MingaEditor.RenderPipeline.TestHelpers, only: [base_state: 1]

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.WorkspaceSymbolSource

  @moduletag :tmp_dir

  test "selecting a symbol in the active file still routes buffer activation", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "active-symbol.ex") |> Path.expand()
    File.write!(path, "defmodule ActiveSymbol do\nend\n")

    {:ok, buffer} = BufferProcess.start_link(file_path: path)
    stale_label = "stale-label.ex"

    state =
      buffer
      |> active_file_state(stale_label)
      |> then(fn state ->
        %{
          state
          | workspace:
              SessionState.set_editing(state.workspace, %{
                state.workspace.editing
                | last_jump_pos: nil
              })
        }
      end)

    item = %Item{id: {path, 1, 2}, label: "ActiveSymbol"}
    new_state = WorkspaceSymbolSource.on_select(item, state)

    assert new_state.workspace.buffers.active == buffer
    assert Buffer.cursor(buffer) == {1, 2}
    assert new_state.workspace.editing.last_jump_pos == {0, 0}
    assert TabBar.active(new_state.shell_runtime.state.tab_bar).label == "active-symbol.ex"
    refute TabBar.active(new_state.shell_runtime.state.tab_bar).label == stale_label
  end

  defp active_file_state(buffer, stale_label) do
    state = base_state(content: "scratch")
    buffers = %Buffers{active: buffer, list: [buffer], active_index: 0}
    workspace = SessionState.set_buffers(state.workspace, buffers)

    tab = Tab.new_file(1, stale_label) |> Tab.set_context(TabContext.from_workspace(workspace))
    tab_bar = %TabBar{tabs: [tab], active_id: 1, next_id: 2}
    shell_state = ShellState.install_tab_bar(state.shell_runtime.state, tab_bar)

    %{
      state
      | workspace: workspace,
        shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end
end
