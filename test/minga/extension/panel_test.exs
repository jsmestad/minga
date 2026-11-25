defmodule Minga.Extension.PanelTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Panel

  # Each test owns its table.
  # A panel set in the application's table reaches every editor state that reads that table, in any test.
  setup do
    table = Module.concat(__MODULE__, "Table#{System.unique_integer([:positive])}")
    start_supervised!({Panel, name: table})
    %{table: table}
  end

  describe "set/4 and all/1" do
    test "registers a panel with content blocks", %{table: table} do
      :ok =
        Panel.set(table, :test_ext, "main", %{
          title: "Test Panel",
          position: :bottom,
          size: {:percent, 30},
          visible: true,
          content: [
            {:text, "Hello"},
            {:separator},
            {:key_value, [{"Key", "Value"}]}
          ]
        })

      panels = Panel.all(table)
      assert Enum.count(panels) == 1

      [panel] = panels
      assert panel.extension == :test_ext
      assert panel.title == "Test Panel"
      assert panel.position == :bottom
      assert panel.visible == true
      assert Enum.count(panel.content) == 3
    end

    test "replaces panel with same key", %{table: table} do
      :ok = Panel.set(table, :test_ext, "main", %{title: "v1"})
      :ok = Panel.set(table, :test_ext, "main", %{title: "v2"})

      assert Enum.count(Panel.all(table)) == 1
      assert hd(Panel.all(table)).title == "v2"
    end
  end

  describe "visible/1" do
    test "returns only visible panels", %{table: table} do
      :ok = Panel.set(table, :test_ext, "a", %{visible: true, title: "Visible"})
      :ok = Panel.set(table, :test_ext, "b", %{visible: false, title: "Hidden"})

      visible = Panel.visible(table)
      assert Enum.count(visible) == 1
      assert hd(visible).title == "Visible"
    end
  end

  describe "hide/3 and show/3" do
    test "toggles panel visibility", %{table: table} do
      :ok = Panel.set(table, :test_ext, "main", %{visible: true, title: "Panel"})
      assert Enum.count(Panel.visible(table)) == 1

      :ok = Panel.hide(table, :test_ext, "main")
      assert Panel.visible(table) == []

      :ok = Panel.show(table, :test_ext, "main")
      assert Enum.count(Panel.visible(table)) == 1
    end
  end

  describe "remove/3 and remove_all/2" do
    test "removes a specific panel", %{table: table} do
      :ok = Panel.set(table, :test_ext, "a", %{title: "A"})
      :ok = Panel.set(table, :test_ext, "b", %{title: "B"})
      :ok = Panel.remove(table, :test_ext, "a")

      panels = Panel.all(table)
      assert Enum.count(panels) == 1
      assert hd(panels).panel_id == "b"
    end

    test "removes all panels for an extension", %{table: table} do
      :ok = Panel.set(table, :test_ext, "a", %{title: "A"})
      :ok = Panel.set(table, :other_ext, "b", %{title: "B"})
      :ok = Panel.remove_all(table, :test_ext)

      panels = Panel.all(table)
      assert Enum.count(panels) == 1
      assert hd(panels).extension == :other_ext
    end
  end

  describe "unregister_source/2" do
    test "removes all panels for an extension source", %{table: table} do
      :ok = Panel.set(table, :test_ext, "a", %{title: "A"})
      :ok = Panel.unregister_source(table, {:extension, :test_ext})
      assert Panel.all(table) == []
    end
  end

  describe "content block types" do
    test "table content block", %{table: table} do
      :ok =
        Panel.set(table, :test_ext, "table_test", %{
          content: [
            {:table, %{columns: ["Name", "Status"], rows: [["Claude", "thinking"]], selected: 0}}
          ]
        })

      [panel] = Panel.all(table)
      [{:table, block}] = panel.content
      assert block.columns == ["Name", "Status"]
      assert block.rows == [["Claude", "thinking"]]
    end

    test "progress content block", %{table: table} do
      :ok =
        Panel.set(table, :test_ext, "progress_test", %{
          content: [{:progress, %{label: "Loading", percent: 0.75}}]
        })

      [panel] = Panel.all(table)
      [{:progress, progress}] = panel.content
      assert progress.label == "Loading"
      assert progress.percent == 0.75
    end

    test "tree content block", %{table: table} do
      :ok =
        Panel.set(table, :test_ext, "tree_test", %{
          content: [
            {:tree,
             %{
               nodes: [
                 %{label: "Root", expanded: true, children: [%{label: "Child", children: []}]}
               ]
             }}
          ]
        })

      [panel] = Panel.all(table)
      [{:tree, tree}] = panel.content
      assert Enum.count(tree.nodes) == 1
      assert hd(tree.nodes).label == "Root"
    end
  end
end
