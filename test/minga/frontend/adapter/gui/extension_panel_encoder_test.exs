defmodule Minga.Frontend.Adapter.GUI.ExtensionPanelEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.ExtensionPanelEncoder
  alias Minga.RenderModel.UI.ExtensionPanel
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
          content: panel().content
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
          {:table, %{columns: ["Name", "Count"], rows: [["alpha", 1], ["beta", 2]], selected: 1}},
          {:unknown_block, %{value: true}}
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
          content: panel.content
        }
      ]

      assert ExtensionPanelEncoder.encode_command(%ExtensionPanel{panels: [panel]}) ==
               ProtocolGUI.encode_gui_extension_panels(legacy_panels)
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
        {:text, "Hello"},
        {:styled_text, [{"Bold", 0x112233, [bold: true]}]},
        {:key_value, [{"Mode", "Ready"}]},
        {:progress, %{label: "Build", percent: 0.42}},
        {:tree, %{nodes: [%{label: "root", expanded: true, children: [%{label: "child"}]}]}},
        {:separator}
      ]
    }
  end
end
