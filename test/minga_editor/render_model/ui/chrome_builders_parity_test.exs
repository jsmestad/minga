defmodule MingaEditor.RenderModel.UI.ChromeBuildersParityTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.RenderModel.UI.TabBarBuilder
  alias MingaEditor.RenderModel.UI.WorkspacesBuilder
  alias MingaEditor.Session.ChromeState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar

  test "tab bar and workspaces preserve the same committed chrome tab projection", %{
    tmp_dir: tmp_dir
  } do
    first = file_tab(1, "first.ex", Path.join(tmp_dir, "first.ex"))
    second = file_tab(2, "second.ex", Path.join(tmp_dir, "second.ex"))
    tab_bar = %TabBar{tabs: [first, second], active_id: 2, next_id: 3}
    ctx = context(tab_bar)
    committed = ChromeState.from_editor_state(ctx)

    tab_bar_model = TabBarBuilder.build(ctx)
    workspaces_model = WorkspacesBuilder.build(ctx)

    assert Enum.map(tab_bar_model.tabs, & &1.id) == Enum.map(committed.visible_tabs, & &1.id)

    assert Enum.map(workspaces_model.visible_tabs, & &1.id) ==
             Enum.map(committed.visible_tabs, & &1.id)

    assert Enum.map(tab_bar_model.tabs, & &1.workspace_id) ==
             Enum.map(workspaces_model.visible_tabs, & &1.workspace_id)

    assert Enum.map(tab_bar_model.tabs, & &1.label) ==
             Enum.map(workspaces_model.visible_tabs, & &1.label)

    assert tab_bar_model.active_tab_id == committed.active_tab_id
    assert workspaces_model.active_workspace_id == committed.active_workspace_id
  end

  defp file_tab(id, label, path) do
    File.write!(path, "")
    buffer = start_supervised!({BufferProcess, file_path: path}, id: make_ref())
    context = TabContext.from_workspace_map(%{buffers: %Buffers{active: buffer, list: [buffer]}})

    id
    |> Tab.new_file(label)
    |> Tab.set_context(context)
  end

  defp context(tab_bar) do
    %MingaEditor.Frontend.Emit.Context{
      port_manager: self(),
      capabilities: MingaEditor.Frontend.Capabilities.default(),
      theme: MingaEditor.UI.Theme.get!(:doom_one),
      font_registry: MingaEditor.UI.FontRegistry.new(),
      windows: %MingaEditor.State.Windows{map: %{}, active: 1},
      layout: %MingaEditor.Layout{
        terminal: {0, 0, 80, 24},
        editor_area: {0, 0, 80, 24},
        minibuffer: {23, 0, 80, 1},
        window_layouts: %{}
      },
      shell: MingaEditor.Shell.Traditional,
      shell_state: %{tab_bar: tab_bar}
    }
  end
end
