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
    first = file_tab(1, "first.ex", Path.join(tmp_dir, "first.ex"), dirty?: true, pinned?: true)
    second = file_tab(2, "second.ex", Path.join(tmp_dir, "second.ex"))

    agent =
      3
      |> Tab.new_agent("Agent Review")
      |> Tab.set_group(1)
      |> Tab.set_attention(true)

    first = Tab.set_group(first, 1)
    second = Tab.set_group(second, 1)
    seed = TabBar.new(first, tmp_dir)
    {seed, workspace} = TabBar.add_workspace(seed, "Review")

    tab_bar = %TabBar{
      seed
      | tabs: [first, second, agent],
        active_id: 2,
        next_id: 4
    }

    ctx = context(tab_bar)
    committed = ChromeState.from_editor_state(ctx)
    tab_bar_model = TabBarBuilder.build(ctx)
    workspaces_model = WorkspacesBuilder.build(ctx)

    assert workspace.id == 1
    assert committed.active_tab_id == 2
    assert committed.active_workspace_id == 1
    assert Enum.map(committed.visible_tabs, & &1.id) == [3, 1, 2]

    assert Enum.map(tab_bar_model.tabs, &tab_projection/1) == [
             %{
               id: 3,
               workspace_id: 1,
               label: "Agent Review",
               kind: :agent,
               dirty?: false,
               attention?: true,
               pinned?: false
             },
             %{
               id: 1,
               workspace_id: 1,
               label: "first.ex",
               kind: :file,
               dirty?: true,
               attention?: false,
               pinned?: true
             },
             %{
               id: 2,
               workspace_id: 1,
               label: "second.ex",
               kind: :file,
               dirty?: false,
               attention?: false,
               pinned?: false
             }
           ]

    assert Enum.map(workspaces_model.visible_tabs, &workspace_tab_projection/1) == [
             %{
               id: 3,
               workspace_id: 1,
               label: "Agent Review",
               path: nil,
               kind: :agent,
               dirty?: false,
               attention?: true,
               pinned?: false
             },
             %{
               id: 1,
               workspace_id: 1,
               label: "first.ex",
               path: Path.join(tmp_dir, "first.ex"),
               kind: :file,
               dirty?: true,
               attention?: false,
               pinned?: true
             },
             %{
               id: 2,
               workspace_id: 1,
               label: "second.ex",
               path: Path.join(tmp_dir, "second.ex"),
               kind: :file,
               dirty?: false,
               attention?: false,
               pinned?: false
             }
           ]

    assert tab_bar_model.active_tab_id == 2
    assert workspaces_model.active_workspace_id == 1
  end

  defp file_tab(id, label, path, opts \\ []) do
    File.write!(path, "")
    buffer = start_supervised!({BufferProcess, file_path: path}, id: make_ref())

    if opts[:dirty?] do
      :ok = BufferProcess.insert_char(buffer, "x")
    end

    context = TabContext.from_workspace_map(%{buffers: %Buffers{active: buffer, list: [buffer]}})

    id
    |> Tab.new_file(label)
    |> Tab.set_context(context)
    |> Tab.set_pinned(opts[:pinned?] || false)
  end

  defp tab_projection(tab) do
    Map.take(tab, [:id, :workspace_id, :label, :kind, :dirty?, :attention?, :pinned?])
  end

  defp workspace_tab_projection(tab) do
    Map.take(tab, [:id, :workspace_id, :label, :path, :kind, :dirty?, :attention?, :pinned?])
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
      shell_state: %{tab_bar: tab_bar},
      tab_bar: tab_bar
    }
  end
end
