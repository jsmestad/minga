defmodule Minga.Frontend.Adapter.GUI.ExtensionPanelEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.EncodingError
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

    test "emits exact typed panel content bytes" do
      assert ExtensionPanelEncoder.encode_command(%ExtensionPanel{panels: [panel()]}) ==
               <<
                 @op_gui_extension_panel,
                 95::16,
                 1,
                 4,
                 "demo",
                 6,
                 "status",
                 6,
                 "Status",
                 0,
                 0,
                 30,
                 1,
                 6,
                 0,
                 5::16,
                 "Hello",
                 1,
                 1,
                 4::16,
                 "Bold",
                 0x11,
                 0x22,
                 0x33,
                 1,
                 0,
                 3,
                 1,
                 4::16,
                 "Mode",
                 5::16,
                 "Ready",
                 5,
                 5::16,
                 "Build",
                 42::16,
                 6,
                 20::16,
                 1,
                 4::16,
                 "root",
                 1,
                 1,
                 1,
                 5::16,
                 "child",
                 0,
                 0,
                 0,
                 4
               >>
    end

    test "emits exact table, line-sized, and unknown content block bytes" do
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

      assert ExtensionPanelEncoder.encode_command(%ExtensionPanel{panels: [panel]}) ==
               <<
                 @op_gui_extension_panel,
                 62::16,
                 1,
                 4,
                 "demo",
                 5,
                 "table",
                 5,
                 "Table",
                 1,
                 1,
                 7,
                 0,
                 2,
                 2,
                 2,
                 2::16,
                 1::16,
                 4::16,
                 "Name",
                 5::16,
                 "Count",
                 5::16,
                 "alpha",
                 1::16,
                 "1",
                 4::16,
                 "beta",
                 1::16,
                 "2",
                 255
               >>
    end

    test "encodes nil table selection as the direct sentinel" do
      panel = %Panel{
        extension: "demo",
        panel_id: "table",
        title: "Table",
        position: :right,
        size: {:lines, 7},
        visible?: false,
        content: [%Table{columns: [], rows: [], selected: nil}]
      }

      assert ExtensionPanelEncoder.encode_command(%ExtensionPanel{panels: [panel]}) ==
               <<
                 @op_gui_extension_panel,
                 29::16,
                 1,
                 4,
                 "demo",
                 5,
                 "table",
                 5,
                 "Table",
                 1,
                 1,
                 7,
                 0,
                 1,
                 2,
                 0,
                 0::16,
                 0xFFFF::16
               >>
    end

    test "rejects extension-controlled counts before truncating the command" do
      long_text = String.duplicate("å", 300)
      panels = for index <- 1..300, do: oversized_panel(index, long_text)

      error =
        assert_raise EncodingError, fn ->
          ExtensionPanelEncoder.encode_command(%ExtensionPanel{panels: panels})
        end

      assert %{command: :gui_extension_panel, field: :panel_count, actual: 300, min: 0, max: 255} =
               error
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
end
