defmodule Minga.Frontend.Adapter.GUI.HoverPopupEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Face
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.HoverPopupEncoder
  alias Minga.RenderModel.UI.HoverPopup
  alias Minga.RenderModel.UI.HoverPopup.Line
  alias Minga.RenderModel.UI.HoverPopup.Segment
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @op_gui_hover_popup Minga.Protocol.Opcodes.gui_hover_popup()

  describe "encode/2" do
    test "encodes hidden hover popup" do
      model = %HoverPopup{}
      caches = Caches.new()

      {cmd, _caches} = HoverPopupEncoder.encode(model, caches)

      assert cmd == <<@op_gui_hover_popup, 0>>
    end

    test "returns nil on second call with same fingerprint" do
      model = %HoverPopup{}
      caches = Caches.new()

      {cmd1, caches} = HoverPopupEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = HoverPopupEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when semantic fields change" do
      model1 = %HoverPopup{}
      model2 = hover_model()

      caches = Caches.new()
      {_, caches} = HoverPopupEncoder.encode(model1, caches)
      {cmd2, _caches} = HoverPopupEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == HoverPopupEncoder.encode_command(model2)
    end

    test "produces byte-identical output to legacy ProtocolGUI for hidden state" do
      assert HoverPopupEncoder.encode_command(%HoverPopup{}) ==
               ProtocolGUI.encode_gui_hover_popup(nil)
    end

    test "produces byte-identical output to legacy ProtocolGUI for visible popup" do
      legacy = %MingaEditor.HoverPopup{
        content_lines: [
          {[{"hello", :plain}, {"world", {:syntax, Face.new(fg: 0x112233, bold: true)}}], :text}
        ],
        anchor_row: 5,
        anchor_col: 10,
        focused: true,
        scroll_offset: 2,
        open_action: :open_docs
      }

      model = hover_model()

      assert HoverPopupEncoder.encode_command(model) == ProtocolGUI.encode_gui_hover_popup(legacy)
    end
  end

  defp hover_model do
    %HoverPopup{
      visible?: true,
      anchor_row: 5,
      anchor_col: 10,
      focused?: true,
      scroll_offset: 2,
      content_lines: [
        %Line{
          line_type: :text,
          segments: [
            %Segment{text: "hello", style: :plain},
            %Segment{text: "world", style: {:syntax, Face.new(fg: 0x112233, bold: true)}}
          ]
        }
      ],
      open_action_name: "open_docs"
    }
  end
end
