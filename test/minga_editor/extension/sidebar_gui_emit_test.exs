defmodule MingaEditor.Extension.SidebarGUIEmitTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI, as: AdapterGUI
  alias Minga.Frontend.Adapter.GUI.Caches, as: AdapterCaches
  alias Minga.Project.FileTree
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.FileTree.Feature, as: FileTreeFeature
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.GitStatus.Panel, as: GitStatusPanel
  alias MingaEditor.RenderModel.UI.Builder
  alias MingaEditor.Sidebar.BuiltinSurfaces
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState

  import MingaEditor.RenderPipeline.TestHelpers

  setup do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})
    %{sidebar_registry: table}
  end

  test "registered file tree remains visible in GUI sidebar metadata", %{sidebar_registry: table} do
    root = Path.join(System.tmp_dir!(), "sidebar-gui-emit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "a.ex"), "")

    file_tree = FileTreeState.open(%FileTreeState{}, FileTree.new(root, width: 32), nil)
    state = gui_state(sidebar_registry: table) |> EditorState.set_file_tree(file_tree)

    {_ctx, _caches, cmds} = sync_chrome(state)
    {active_id, entries} = cmds |> gui_sidebars_payload!() |> parse_gui_sidebars()

    assert active_id == "file_tree"

    file_tree_entry = Enum.find(entries, &(&1.id == "file_tree"))
    assert file_tree_entry.visible?
    assert file_tree_entry.focused?
  end

  test "registered built-in sidebars are emitted by the sidebar registry", %{
    sidebar_registry: table
  } do
    assert :ok = FileTreeFeature.register_contributions(%FileTreeState{}, table)
    assert :ok = BuiltinSurfaces.register_contributions(table)

    {_ctx, _caches, cmds} = sync_chrome(gui_state(sidebar_registry: table))
    {_active_id, entries} = cmds |> gui_sidebars_payload!() |> parse_gui_sidebars()

    assert Enum.map(entries, & &1.id) == ["file_tree", "git_status", "observatory"]
    assert Enum.all?(entries, &(not &1.visible?))

    observatory = Enum.find(entries, &(&1.id == "observatory"))
    assert observatory.preferred_width == 52
  end

  test "registered git status sidebar metadata carries visibility and badge count", %{
    sidebar_registry: table
  } do
    panel = %GitStatusPanel{
      repo_state: :normal,
      branch: "main",
      ahead: 0,
      behind: 0,
      entries: [
        %Minga.Git.StatusEntry{path: "a.ex", status: :modified, staged: false},
        %Minga.Git.StatusEntry{path: "b.ex", status: :untracked, staged: false}
      ]
    }

    assert :ok = BuiltinSurfaces.sync_git_status_panel(panel, table)

    {_ctx, _caches, cmds} = sync_chrome(gui_state(sidebar_registry: table))
    {active_id, entries} = cmds |> gui_sidebars_payload!() |> parse_gui_sidebars()

    assert active_id == "git_status"

    git_status = Enum.find(entries, &(&1.id == "git_status"))
    assert git_status.visible?
    assert git_status.focused?
    assert git_status.badge_count == 2
  end

  test "registered extension sidebars own the GUI active id over inactive built-ins", %{
    sidebar_registry: table
  } do
    root = Path.join(System.tmp_dir!(), "sidebar-gui-emit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "a.ex"), "")

    file_tree = FileTreeState.open(%FileTreeState{}, FileTree.new(root, width: 32), nil)
    state = gui_state(sidebar_registry: table) |> EditorState.set_file_tree(file_tree)
    FileTreeFeature.sync_sidebar(%FileTreeState{}, table)

    assert :ok =
             Sidebar.register(table, {:extension, :outline}, %{
               id: "outline",
               display_name: "Outline",
               priority: 40,
               preferred_width: 32,
               visible?: true,
               focused?: true,
               semantic_kind: "generic_tree",
               icon: "list.bullet"
             })

    {_ctx, _caches, cmds} = sync_chrome(state)
    {active_id, entries} = cmds |> gui_sidebars_payload!() |> parse_gui_sidebars()

    assert active_id == "outline"

    file_tree_entry = Enum.find(entries, &(&1.id == "file_tree"))
    refute file_tree_entry.visible?
  end

  test "GUI emit includes registered sidebar metadata and skips selection-only snapshot changes",
       %{sidebar_registry: table} do
    state = gui_state(sidebar_registry: table)

    assert :ok =
             Sidebar.register(table, {:extension, :outline}, %{
               id: "outline",
               display_name: "Outline",
               priority: 40,
               preferred_width: 32,
               visible?: true,
               focused?: true,
               semantic_kind: "generic_tree",
               icon: "list.bullet",
               snapshot: [
                 rows: [%{id: "a", text: "alpha", selected?: true}, %{id: "b", text: "beta"}]
               ]
             })

    {_ctx, caches, first_cmds} = sync_chrome(state)
    assert Enum.any?(first_cmds, &match?(<<0x9F, _::binary>>, &1))

    assert :ok =
             Sidebar.publish_snapshot(table, {:extension, :outline}, "outline",
               rows: [%{id: "a", text: "alpha"}, %{id: "b", text: "beta", selected?: true}]
             )

    {_ctx, _caches, second_cmds} = sync_chrome(state, caches)
    refute Enum.any?(second_cmds, &match?(<<0x9F, _::binary>>, &1))
  end

  defp sync_chrome(state, adapter_caches \\ AdapterCaches.new()) do
    ctx = Context.from_editor_state(state)
    {ui_model, ctx} = Builder.build_ui(ctx)
    {cmds, adapter_caches} = AdapterGUI.encode_ui(ui_model, adapter_caches)

    {ctx, adapter_caches, cmds}
  end

  defp gui_sidebars_payload!(cmds) do
    Enum.find_value(cmds, fn
      <<0x9F, payload_len::32, payload::binary-size(payload_len)>> -> payload
      _ -> nil
    end)
  end

  defp parse_gui_sidebars(<<1::8, count::16, rest::binary>>) do
    {active_id, rest} = take_string16(rest)
    {active_id, parse_sidebar_entries(rest, count, [])}
  end

  defp parse_sidebar_entries(_rest, 0, acc), do: Enum.reverse(acc)

  defp parse_sidebar_entries(rest, count, acc) do
    {id, rest} = take_string16(rest)
    {display_name, rest} = take_string16(rest)
    {semantic_kind, rest} = take_string16(rest)
    {icon, rest} = take_string16(rest)
    <<order::16, flags::8, preferred_width::16, badge_count::16, rest::binary>> = rest

    entry = %{
      id: id,
      display_name: display_name,
      semantic_kind: semantic_kind,
      icon: icon,
      order: order,
      visible?: Bitwise.band(flags, 0x01) != 0,
      focused?: Bitwise.band(flags, 0x02) != 0,
      preferred_width: preferred_width,
      badge_count: badge_count
    }

    parse_sidebar_entries(rest, count - 1, [entry | acc])
  end

  defp take_string16(<<len::16, value::binary-size(len), rest::binary>>), do: {value, rest}
end
