defmodule MingaEditor.RenderModel.UI.ExtensionPanelBuilderTest do
  # Uses the process-global extension panel registry.
  use ExUnit.Case, async: false

  alias Minga.Extension.Panel, as: ExtensionPanelRegistry
  alias Minga.RenderModel.UI.ExtensionPanel
  alias Minga.RenderModel.UI.ExtensionPanel.Content.KeyValue
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Progress
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Separator
  alias Minga.RenderModel.UI.ExtensionPanel.Content.StyledRun
  alias Minga.RenderModel.UI.ExtensionPanel.Content.StyledText
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Table
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Text
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Tree
  alias Minga.RenderModel.UI.ExtensionPanel.Content.TreeNode
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Unknown
  alias Minga.RenderModel.UI.ExtensionPanel.Panel
  alias MingaEditor.RenderModel.UI.ExtensionPanelBuilder

  setup do
    ExtensionPanelRegistry.remove_all(:builder_test)
    ExtensionPanelRegistry.remove_all(:builder_other)

    on_exit(fn ->
      ExtensionPanelRegistry.remove_all(:builder_test)
      ExtensionPanelRegistry.remove_all(:builder_other)
    end)

    :ok
  end

  describe "build/0" do
    test "builds extension panel model with empty panels" do
      model = ExtensionPanelBuilder.build()

      assert %ExtensionPanel{} = model
      assert model.panels == []
    end

    test "maps visible extension panels into semantic content blocks" do
      :ok =
        ExtensionPanelRegistry.set(:builder_test, :status, %{
          title: "Status",
          position: :right,
          size: {:lines, 8},
          visible: true,
          content: [
            {:text, "Hello"},
            {:styled_text, [{"Bold", 0x112233, [bold: true]}]},
            {:table, %{columns: ["Name"], rows: [["Minga"]], selected: 0}},
            {:key_value, [{"Mode", "Ready"}]},
            {:separator},
            {:progress, %{label: "Build", percent: 0.42}},
            {:tree, %{nodes: [%{label: "root", expanded: true, children: [%{label: "child"}]}]}},
            {:future_block, %{value: true}}
          ]
        })

      :ok = ExtensionPanelRegistry.set(:builder_other, :hidden, %{visible: false})

      model = ExtensionPanelBuilder.build()

      assert %ExtensionPanel{panels: [%Panel{} = panel]} = model
      assert panel.extension == "builder_test"
      assert panel.panel_id == "status"
      assert panel.title == "Status"
      assert panel.position == :right
      assert panel.size == {:lines, 8}
      assert panel.visible?

      assert [
               %Text{text: "Hello"},
               %StyledText{
                 runs: [
                   %StyledRun{text: "Bold", fg: 0x112233, attrs: %{bold?: true, italic?: false}}
                 ]
               },
               %Table{columns: ["Name"], rows: [["Minga"]], selected: 0},
               %KeyValue{pairs: [{"Mode", "Ready"}]},
               %Separator{},
               %Progress{label: "Build", percent: 0.42},
               %Tree{
                 nodes: [
                   %TreeNode{
                     label: "root",
                     expanded?: true,
                     children: [%TreeNode{label: "child", expanded?: false, children: []}]
                   }
                 ]
               },
               %Unknown{}
             ] = panel.content
    end

    test "normalizes malformed extension panel content into semantic defaults" do
      :ok =
        ExtensionPanelRegistry.set(:builder_test, :malformed, %{
          title: "Broken",
          position: :center,
          size: {:lines, 0},
          visible: true,
          content: [
            {:text, 123},
            {:styled_text, [{"Styled", :bad, []}]},
            {:table, %{columns: :bad, rows: :bad, selected: :bad}},
            {:key_value, :bad},
            {:separator},
            {:progress, %{label: :bad, percent: :bad}},
            {:tree, %{nodes: :bad}},
            {:future_block, %{value: true}}
          ]
        })

      model = ExtensionPanelBuilder.build()

      assert %ExtensionPanel{panels: [%Panel{} = panel]} = model
      assert panel.extension == "builder_test"
      assert panel.panel_id == "malformed"
      assert panel.title == "Broken"
      assert panel.position == :bottom
      assert panel.size == {:percent, 30}
      assert panel.visible?

      assert [
               %Text{text: "123"},
               %StyledText{
                 runs: [
                   %StyledRun{text: "Styled", fg: 0, attrs: %{bold?: false, italic?: false}}
                 ]
               },
               %Table{columns: [], rows: [], selected: nil},
               %KeyValue{pairs: []},
               %Separator{},
               %Progress{label: "bad", percent: 0},
               %Tree{nodes: []},
               %Unknown{}
             ] = panel.content
    end

    test "treats non-list panel content as an empty content list" do
      :ok =
        ExtensionPanelRegistry.set(:builder_test, :non_list_content, %{
          title: "Empty",
          visible: true,
          content: :bad
        })

      model = ExtensionPanelBuilder.build()

      assert %ExtensionPanel{panels: [%Panel{} = panel]} = model
      assert panel.extension == "builder_test"
      assert panel.panel_id == "non_list_content"
      assert panel.content == []
    end
  end
end
