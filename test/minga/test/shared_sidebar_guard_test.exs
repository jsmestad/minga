defmodule Minga.Test.SharedSidebarGuardTest do
  use ExUnit.Case, async: true

  alias Minga.Test.SharedSidebarGuard
  alias MingaEditor.Extension.Sidebar

  setup do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})
    {:ok, table: table}
  end

  test "a table with no sidebar on screen has nothing open", %{table: table} do
    assert :ok =
             Sidebar.register(table, {:extension, :outline}, %{
               id: "outline",
               display_name: "Outline"
             })

    assert SharedSidebarGuard.open_ids(table) == []
  end

  test "a sidebar opened and focused during the run and not closed is reported", %{table: table} do
    source = {:extension, :outline}
    assert :ok = Sidebar.register(table, source, %{id: "outline", display_name: "Outline"})
    before = SharedSidebarGuard.open_ids(table)

    assert :ok = Sidebar.set_visible(table, source, "outline", true)
    assert :ok = Sidebar.focus_left(table, "outline")
    assert SharedSidebarGuard.left_open(before, SharedSidebarGuard.open_ids(table)) == ["outline"]

    assert :ok = Sidebar.set_visible(table, source, "outline", false)
    assert SharedSidebarGuard.left_open(before, SharedSidebarGuard.open_ids(table)) == []
  end

  test "a sidebar that was already open when the suite started is not a leak", %{table: table} do
    assert :ok =
             Sidebar.register(table, {:extension, :outline}, %{
               id: "outline",
               display_name: "Outline",
               visible?: true,
               focused?: true
             })

    before = SharedSidebarGuard.open_ids(table)
    assert SharedSidebarGuard.left_open(before, SharedSidebarGuard.open_ids(table)) == []
  end
end
