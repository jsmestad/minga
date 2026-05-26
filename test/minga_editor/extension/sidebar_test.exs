defmodule MingaEditor.Extension.SidebarTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Extension.Sidebar.Snapshot

  setup do
    table = Module.concat(__MODULE__, "Table#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table})
    %{table: table}
  end

  test "registers visible sidebars ordered by priority", %{table: table} do
    assert :ok =
             Sidebar.register(table, {:extension, :alpha}, %{
               id: "outline",
               display_name: "Outline",
               priority: 20,
               preferred_width: 24,
               visible?: true,
               semantic_kind: "generic_tree",
               icon: "list.bullet"
             })

    assert :ok =
             Sidebar.register(table, {:extension, :beta}, %{
               id: "bookmarks",
               display_name: "Bookmarks",
               priority: 10,
               visible?: true
             })

    assert Enum.map(Sidebar.visible(table), & &1.id) == ["bookmarks", "outline"]
  end

  test "rejects reserved built-in sidebar ids from extension sources", %{table: table} do
    assert {:error, {:reserved_sidebar_id, "file_tree"}} =
             Sidebar.register(table, {:extension, :alpha}, %{
               id: "file_tree",
               display_name: "File Tree"
             })
  end

  test "rejects duplicate sidebar ids from different sources", %{table: table} do
    assert :ok =
             Sidebar.register(table, {:extension, :alpha}, %{
               id: "outline",
               display_name: "Outline"
             })

    assert {:error, {:duplicate_sidebar_id, "outline", {:extension, :alpha}}} =
             Sidebar.register(table, {:extension, :beta}, %{id: "outline", display_name: "Other"})
  end

  test "allows the owning source to replace and remove its sidebar", %{table: table} do
    source = {:extension, :alpha}
    assert :ok = Sidebar.register(table, source, %{id: "outline", display_name: "Outline"})

    assert :ok =
             Sidebar.register(table, source, %{
               id: "outline",
               display_name: "Symbols",
               visible?: true
             })

    assert %{display_name: "Symbols", visible?: true} = Sidebar.get(table, "outline")
    assert :ok = Sidebar.unregister(table, source, "outline")
    assert Sidebar.get(table, "outline") == nil
  end

  test "publishes snapshots without changing registration metadata", %{table: table} do
    source = {:extension, :alpha}
    rows = [%{id: "a", text: "alpha"}, %{id: "b", text: "beta", selected?: true}]

    assert :ok = Sidebar.register(table, source, %{id: "outline", display_name: "Outline"})
    assert :ok = Sidebar.publish_snapshot(table, source, "outline", rows: rows)

    assert %{display_name: "Outline", snapshot: %Snapshot{rows: ^rows, selected_id: "b"}} =
             Sidebar.get(table, "outline")
  end

  test "active_left prefers focused visible sidebars before priority fallback", %{table: table} do
    assert :ok =
             Sidebar.register(table, {:extension, :alpha}, %{
               id: "outline",
               display_name: "Outline",
               priority: 10,
               visible?: true,
               focused?: false
             })

    assert :ok =
             Sidebar.register(table, {:extension, :beta}, %{
               id: "bookmarks",
               display_name: "Bookmarks",
               priority: 20,
               visible?: true,
               focused?: true
             })

    assert %{id: "bookmarks"} = Sidebar.active_left(table)
  end

  test "focus_left makes one visible left sidebar active", %{table: table} do
    assert :ok =
             Sidebar.register(table, {:extension, :alpha}, %{
               id: "outline",
               display_name: "Outline",
               priority: 10,
               visible?: true,
               focused?: true
             })

    assert :ok =
             Sidebar.register(table, {:extension, :beta}, %{
               id: "bookmarks",
               display_name: "Bookmarks",
               priority: 20,
               visible?: true,
               focused?: false
             })

    assert :ok = Sidebar.focus_left(table, "bookmarks")

    refute Sidebar.get(table, "outline").focused?
    assert Sidebar.get(table, "bookmarks").focused?
    assert %{id: "bookmarks"} = Sidebar.active_left(table)
  end

  test "source cleanup removes only matching source sidebars", %{table: table} do
    assert :ok =
             Sidebar.register(table, {:extension, :alpha}, %{
               id: "outline",
               display_name: "Outline"
             })

    assert :ok =
             Sidebar.register(table, {:extension, :beta}, %{
               id: "bookmarks",
               display_name: "Bookmarks"
             })

    assert :ok = Sidebar.unregister_source(table, {:extension, :alpha})

    assert Sidebar.get(table, "outline") == nil
    assert %{id: "bookmarks"} = Sidebar.get(table, "bookmarks")
  end

  test "dispatches actions through the editor action pipeline", %{table: table} do
    handler = fn state, action, context -> Map.put(state, :handled, {action, context}) end

    assert :ok =
             Sidebar.register(table, {:extension, :alpha}, %{
               id: "outline",
               display_name: "Outline",
               action_handler: handler
             })

    state = Sidebar.dispatch_action(table, %{}, "outline", "open", %{row: 1})
    assert state.handled == {"open", %{row: 1, sidebar_id: "outline"}}
  end
end
