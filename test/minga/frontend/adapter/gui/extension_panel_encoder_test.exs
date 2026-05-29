defmodule Minga.Frontend.Adapter.GUI.ExtensionPanelEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.ExtensionPanelEncoder
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
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @op_gui_extension_panel Minga.Protocol.Opcodes.gui_extension_panel()

  describe "encode/2" do
    test "encodes empty extension panel" do
      model = %ExtensionPanel{}
      caches = Caches.new()

      {cmd, _caches} = ExtensionPanelEncoder.encode(model, caches)

      assert cmd == <<@op_gui_extension_panel, 1::16, 0>>
    end

    test "returns nil on second call with same fingerprint" do
      model = %ExtensionPanel{}
      caches = Caches.new()

      {cmd1, caches} = ExtensionPanelEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = ExtensionPanelEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when semantic panels change" do
      model1 = %ExtensionPanel{}
      model2 = %ExtensionPanel{panels: [panel()]}

      caches = Caches.new()
      {_, caches} = ExtensionPanelEncoder.encode(model1, caches)
      {cmd2, _caches} = ExtensionPanelEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == ExtensionPanelEncoder.encode_command(model2)
    end

    test "produces byte-identical output to legacy ProtocolGUI for empty panels" do
      assert ExtensionPanelEncoder.encode_command(%ExtensionPanel{}) ==
               ProtocolGUI.encode_gui_extension_panels([])
    end

    test "produces byte-identical output to legacy ProtocolGUI for panel content" do
      model = %ExtensionPanel{panels: [panel()]}

      legacy_panels = [
        %{
          extension: :demo,
          panel_id: :status,
          title: "Status",
          position: :bottom,
          size: {:percent, 30},
          visible: true,
          content: legacy_content(panel().content)
        }
      ]

      assert ExtensionPanelEncoder.encode_command(model) ==
               ProtocolGUI.encode_gui_extension_panels(legacy_panels)
    end

    test "produces byte-identical output for table, line-sized, and unknown content blocks" do
      panel = %Panel{
        extension: "demo",
        panel_id: "table",
        title: "Table",
        position: :right,
        size: {:lines, 7},
        visible?: false,
        content: [
          %Table{columns: ["Name", "Count"], rows: [["alpha", "1"], ["beta", "2"]], selected: 1},
          %Unknown{}
        ]
      }

      legacy_panels = [
        %{
          extension: :demo,
          panel_id: :table,
          title: "Table",
          position: :right,
          size: {:lines, 7},
          visible: false,
          content: legacy_content(panel.content)
        }
      ]

      assert ExtensionPanelEncoder.encode_command(%ExtensionPanel{panels: [panel]}) ==
               ProtocolGUI.encode_gui_extension_panels(legacy_panels)
    end

    test "encodes nil table selection as the legacy sentinel" do
      panel = %Panel{
        extension: "demo",
        panel_id: "table",
        title: "Table",
        position: :right,
        size: {:lines, 7},
        visible?: false,
        content: [
          %Table{
            columns: ["Name", "Count"],
            rows: [["alpha", "1"], ["beta", "2"]],
            selected: nil
          },
          %Unknown{}
        ]
      }

      legacy_panels = [
        %{
          extension: :demo,
          panel_id: :table,
          title: "Table",
          position: :right,
          size: {:lines, 7},
          visible: false,
          content: legacy_content(panel.content)
        }
      ]

      assert ExtensionPanelEncoder.encode_command(%ExtensionPanel{panels: [panel]}) ==
               ProtocolGUI.encode_gui_extension_panels(legacy_panels)
    end

    test "bounds extension-controlled counts and 8-bit strings" do
      long_text = String.duplicate("å", 300)
      panels = for index <- 1..300, do: oversized_panel(index, long_text)

      command = ExtensionPanelEncoder.encode_command(%ExtensionPanel{panels: panels})

      <<@op_gui_extension_panel, payload_len::16, payload::binary-size(payload_len)>> = command
      <<panel_count::8, first_panel::binary>> = payload

      <<ext_len::8, ext::binary-size(ext_len), panel_id_len::8,
        panel_id::binary-size(panel_id_len), title_len::8, title::binary-size(title_len),
        _rest::binary>> = first_panel

      assert panel_count <= 255
      assert ext_len <= 255
      assert panel_id_len <= 255
      assert title_len <= 255
      assert String.valid?(ext)
      assert String.valid?(panel_id)
      assert String.valid?(title)
    end
  end

  defp panel do
    %Panel{
      extension: "demo",
      panel_id: "status",
      title: "Status",
      position: :bottom,
      size: {:percent, 30},
      visible?: true,
      content: [
        %Text{text: "Hello"},
        %StyledText{
          runs: [%StyledRun{text: "Bold", fg: 0x112233, attrs: %{bold?: true, italic?: false}}]
        },
        %KeyValue{pairs: [{"Mode", "Ready"}]},
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
        %Separator{}
      ]
    }
  end

  defp oversized_panel(index, long_text) do
    %Panel{
      extension: long_text,
      panel_id: "panel-#{index}-#{long_text}",
      title: long_text,
      position: :bottom,
      size: {:percent, 30},
      visible?: true,
      content: [
        %StyledText{
          runs:
            for(
              run <- 1..300,
              do: %StyledRun{
                text: "run-#{run}",
                fg: 0x112233,
                attrs: %{bold?: true, italic?: false}
              }
            )
        },
        %Tree{
          nodes:
            for(
              node <- 1..300,
              do: %TreeNode{label: "node-#{node}", expanded?: true, children: []}
            )
        }
      ]
    }
  end

  defp legacy_content(blocks), do: Enum.map(blocks, &legacy_content_block/1)
  defp legacy_content_block(%Text{text: text}), do: {:text, text}

  defp legacy_content_block(%StyledText{runs: runs}) do
    {:styled_text,
     Enum.map(runs, fn %StyledRun{} = run -> {run.text, run.fg, legacy_attrs(run)} end)}
  end

  defp legacy_content_block(%Table{} = table) do
    {:table,
     %{
       columns: table.columns,
       rows: table.rows,
       selected: legacy_table_selected(table.selected)
     }}
  end

  defp legacy_content_block(%KeyValue{pairs: pairs}), do: {:key_value, pairs}
  defp legacy_content_block(%Separator{}), do: {:separator}

  defp legacy_content_block(%Progress{} = progress),
    do: {:progress, %{label: progress.label, percent: progress.percent}}

  defp legacy_content_block(%Tree{nodes: nodes}),
    do: {:tree, %{nodes: Enum.map(nodes, &legacy_tree_node/1)}}

  defp legacy_content_block(%Unknown{}), do: {:unknown_block, %{}}

  defp legacy_table_selected(nil), do: 0xFFFF
  defp legacy_table_selected(selected) when is_integer(selected) and selected >= 0, do: selected
  defp legacy_table_selected(_selected), do: 0xFFFF

  defp legacy_tree_node(%TreeNode{} = node) do
    %{
      label: node.label,
      expanded: node.expanded?,
      children: Enum.map(node.children, &legacy_tree_node/1)
    }
  end

  defp legacy_attrs(%StyledRun{} = run) do
    [bold: Map.get(run.attrs, :bold?, false), italic: Map.get(run.attrs, :italic?, false)]
  end
end
