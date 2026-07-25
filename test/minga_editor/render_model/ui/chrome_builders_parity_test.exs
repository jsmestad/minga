defmodule MingaEditor.RenderModel.UI.ChromeBuildersParityTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.RenderModel.UI.TabBarBuilder
  alias MingaEditor.RenderModel.UI.WorkspacesBuilder
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar

  test "tab bar and workspaces preserve the same committed chrome tab projection", %{
    tmp_dir: tmp_dir
  } do
    first = file_tab(1, "first.ex", Path.join(tmp_dir, "first.ex"), dirty?: true, pinned?: true)

    {second, active} =
      file_tab(2, "second.ex", Path.join(tmp_dir, "second.ex"),
        dirty?: true,
        context?: false,
        return_buffer?: true
      )

    agent =
      3
      |> Tab.new_agent("Agent Review")
      |> Tab.set_group(1)
      |> Tab.set_attention(true)

    first = Tab.set_group(first, 1)
    second = Tab.set_group(second, 1)
    seed = TabBar.new(first, tmp_dir)
    {seed, _workspace} = TabBar.add_workspace(seed, "Review")

    tab_bar = %TabBar{
      seed
      | tabs: [first, second, agent],
        active_id: 2,
        next_id: 4
    }

    ctx = context(tab_bar, active)
    tab_bar_model = TabBarBuilder.build(ctx)
    workspaces_model = WorkspacesBuilder.build(ctx)

    assert Enum.map(tab_bar_model.tabs, & &1.id) == [3, 1, 2]

    assert tab_bar_model.tabs |> Enum.find(&(&1.id == 2)) |> tab_projection() == %{
             id: 2,
             workspace_id: 1,
             label: "second.ex",
             kind: :file,
             dirty?: true,
             attention?: false,
             pinned?: false
           }

    assert workspaces_model.visible_tabs |> Enum.find(&(&1.id == 2)) |> workspace_tab_projection() ==
             %{
               id: 2,
               workspace_id: 1,
               label: "second.ex",
               path: Path.join(tmp_dir, "second.ex"),
               kind: :file,
               dirty?: true,
               attention?: false,
               pinned?: false
             }
  end

  defp file_tab(id, label, path, opts) do
    File.write!(path, "")
    buffer = start_supervised!({BufferProcess, file_path: path}, id: make_ref())

    if opts[:dirty?] do
      :ok = BufferProcess.insert_char(buffer, "x")
    end

    context = TabContext.from_workspace_map(%{buffers: %Buffers{active: buffer, list: [buffer]}})

    tab =
      id
      |> Tab.new_file(label)
      |> maybe_set_context(context, opts[:context?] != false)
      |> Tab.set_pinned(opts[:pinned?] || false)

    if opts[:return_buffer?], do: {tab, buffer}, else: tab
  end

  defp tab_projection(tab) do
    Map.take(tab, [:id, :workspace_id, :label, :kind, :dirty?, :attention?, :pinned?])
  end

  defp workspace_tab_projection(tab) do
    Map.take(tab, [:id, :workspace_id, :label, :path, :kind, :dirty?, :attention?, :pinned?])
  end

  defp context(tab_bar, active_buffer) do
    ctx =
      TestHelpers.base_state(port_manager: nil)
      |> Context.from_editor_state()

    frame = %{ctx.intent.frame | shell_state: %{tab_bar: tab_bar}}

    workspace =
      if active_buffer,
        do: %{ctx.workspace | buffers: %Buffers{active: active_buffer, list: [active_buffer]}},
        else: ctx.workspace

    %{ctx | intent: %{ctx.intent | frame: frame}, tab_bar: tab_bar, workspace: workspace}
  end

  defp maybe_set_context(tab, context, true), do: Tab.set_context(tab, context)
  defp maybe_set_context(tab, _context, false), do: tab
end
