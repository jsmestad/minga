defmodule Minga.Extension.PanelTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Panel

  setup do
    table = :"panel_test_#{System.unique_integer([:positive])}"
    :ets.new(table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, table: table}
  end

  describe "set and all" do
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
      assert length(panels) == 1

      [panel] = panels
      assert panel.extension == :test_ext
      assert panel.title == "Test Panel"
      assert panel.position == :bottom
      assert panel.visible == true
      assert length(panel.content) == 3
    end

    test "replaces panel with same key", %{table: table} do
      :ok = Panel.set(table, :test_ext, "main", %{title: "v1"})
      :ok = Panel.set(table, :test_ext, "main", %{title: "v2"})

      assert length(Panel.all(table)) == 1
      assert hd(Panel.all(table)).title == "v2"
    end
  end

  describe "visible" do
    test "returns only visible panels", %{table: table} do
      :ok = Panel.set(table, :test_ext, "a", %{visible: true, title: "Visible"})
      :ok = Panel.set(table, :test_ext, "b", %{visible: false, title: "Hidden"})

      visible = Panel.visible(table)
      assert length(visible) == 1
      assert hd(visible).title == "Visible"
    end
  end

  describe "remove and remove_all" do
    test "removes a specific panel", %{table: table} do
      :ok = Panel.set(table, :test_ext, "a", %{title: "A"})
      :ok = Panel.set(table, :test_ext, "b", %{title: "B"})
      :ok = Panel.remove(table, :test_ext, "a")

      panels = Panel.all(table)
      assert length(panels) == 1
      assert hd(panels).panel_id == "b"
    end

    test "removes all panels for an extension", %{table: table} do
      :ok = Panel.set(table, :test_ext, "a", %{title: "A"})
      :ok = Panel.set(table, :other_ext, "b", %{title: "B"})
      :ok = Panel.remove_all(table, :test_ext)

      panels = Panel.all(table)
      assert length(panels) == 1
      assert hd(panels).extension == :other_ext
    end
  end

  describe "empty?" do
    test "returns true when no panels registered", %{table: table} do
      assert Panel.empty?(table)
    end

    test "returns false when panels exist", %{table: table} do
      :ok = Panel.set(table, :test_ext, "a", %{title: "A"})
      refute Panel.empty?(table)
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
      [{:table, tbl}] = panel.content
      assert tbl.columns == ["Name", "Status"]
      assert tbl.rows == [["Claude", "thinking"]]
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
      assert length(tree.nodes) == 1
      assert hd(tree.nodes).label == "Root"
    end
  end
end
