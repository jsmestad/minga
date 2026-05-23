defmodule Minga.Extension.PanelTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Panel

  setup do
    on_exit(fn ->
      Panel.remove_all(:test_ext)
      Panel.remove_all(:other_ext)
    end)

    :ok
  end

  describe "set/3 and all/0" do
    test "registers a panel with content blocks" do
      :ok =
        Panel.set(:test_ext, "main", %{
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

      panels = Panel.all()
      assert length(panels) == 1

      [panel] = panels
      assert panel.extension == :test_ext
      assert panel.title == "Test Panel"
      assert panel.position == :bottom
      assert panel.visible == true
      assert length(panel.content) == 3
    end

    test "replaces panel with same key" do
      :ok = Panel.set(:test_ext, "main", %{title: "v1"})
      :ok = Panel.set(:test_ext, "main", %{title: "v2"})

      assert length(Panel.all()) == 1
      assert hd(Panel.all()).title == "v2"
    end
  end

  describe "visible/0" do
    test "returns only visible panels" do
      :ok = Panel.set(:test_ext, "a", %{visible: true, title: "Visible"})
      :ok = Panel.set(:test_ext, "b", %{visible: false, title: "Hidden"})

      visible = Panel.visible()
      assert length(visible) == 1
      assert hd(visible).title == "Visible"
    end
  end

  describe "hide/2 and show/2" do
    test "toggles panel visibility" do
      :ok = Panel.set(:test_ext, "main", %{visible: true, title: "Panel"})
      assert length(Panel.visible()) == 1

      :ok = Panel.hide(:test_ext, "main")
      assert Panel.visible() == []

      :ok = Panel.show(:test_ext, "main")
      assert length(Panel.visible()) == 1
    end
  end

  describe "remove/2 and remove_all/1" do
    test "removes a specific panel" do
      :ok = Panel.set(:test_ext, "a", %{title: "A"})
      :ok = Panel.set(:test_ext, "b", %{title: "B"})
      :ok = Panel.remove(:test_ext, "a")

      panels = Panel.all()
      assert length(panels) == 1
      assert hd(panels).panel_id == "b"
    end

    test "removes all panels for an extension" do
      :ok = Panel.set(:test_ext, "a", %{title: "A"})
      :ok = Panel.set(:other_ext, "b", %{title: "B"})
      :ok = Panel.remove_all(:test_ext)

      panels = Panel.all()
      assert length(panels) == 1
      assert hd(panels).extension == :other_ext
    end
  end

  describe "unregister_source/1" do
    test "removes all panels for an extension source" do
      :ok = Panel.set(:test_ext, "a", %{title: "A"})
      :ok = Panel.unregister_source({:extension, :test_ext})
      assert Panel.all() == []
    end
  end

  describe "content block types" do
    test "table content block" do
      :ok =
        Panel.set(:test_ext, "table_test", %{
          content: [
            {:table, %{columns: ["Name", "Status"], rows: [["Claude", "thinking"]], selected: 0}}
          ]
        })

      [panel] = Panel.all()
      [{:table, table}] = panel.content
      assert table.columns == ["Name", "Status"]
      assert table.rows == [["Claude", "thinking"]]
    end

    test "progress content block" do
      :ok =
        Panel.set(:test_ext, "progress_test", %{
          content: [{:progress, %{label: "Loading", percent: 0.75}}]
        })

      [panel] = Panel.all()
      [{:progress, progress}] = panel.content
      assert progress.label == "Loading"
      assert progress.percent == 0.75
    end

    test "tree content block" do
      :ok =
        Panel.set(:test_ext, "tree_test", %{
          content: [
            {:tree,
             %{
               nodes: [
                 %{label: "Root", expanded: true, children: [%{label: "Child", children: []}]}
               ]
             }}
          ]
        })

      [panel] = Panel.all()
      [{:tree, tree}] = panel.content
      assert length(tree.nodes) == 1
      assert hd(tree.nodes).label == "Root"
    end
  end
end
