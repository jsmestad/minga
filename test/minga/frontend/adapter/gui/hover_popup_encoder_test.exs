defmodule Minga.Frontend.Adapter.GUI.HoverPopupEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Face
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.HoverPopupEncoder
  alias Minga.RenderModel.UI.HoverPopup
  alias Minga.RenderModel.UI.HoverPopup.Line
  alias Minga.RenderModel.UI.HoverPopup.Segment

  @op_gui_hover_popup Minga.Protocol.Opcodes.gui_hover_popup()
  @op_gui_hover_action Minga.Protocol.Opcodes.gui_hover_action()

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

    test "encodes hidden hover popup command directly" do
      assert HoverPopupEncoder.encode_command(%HoverPopup{}) == <<@op_gui_hover_popup, 0>>
    end

    test "encodes visible popup with hidden action sidecar" do
      model = %HoverPopup{
        visible?: true,
        anchor_row: 1,
        anchor_col: 2,
        content_lines: [
          %Line{line_type: :text, segments: [%Segment{text: "hello", style: :plain}]}
        ]
      }

      assert HoverPopupEncoder.encode_command(model) ==
               <<@op_gui_hover_popup, 1, 1::16, 2::16, 0, 0::16, 1::16, 0, 1::16, 0, 5::16,
                 "hello", @op_gui_hover_action, 1::16, 0>>
    end

    test "encodes visible popup with syntax segment and open action sidecar" do
      assert HoverPopupEncoder.encode_command(hover_model()) ==
               <<@op_gui_hover_popup, 1, 5::16, 10::16, 1, 2::16, 1::16, 0, 2::16, 0, 5::16,
                 "hello", 13, 0x11, 0x22, 0x33, 0x01, 5::16, "world", @op_gui_hover_action,
                 12::16, 1, 9::16, "open_docs">>
    end

    test "encodes syntax fallback foreground" do
      model = %HoverPopup{
        visible?: true,
        content_lines: [
          %Line{
            line_type: :code,
            segments: [%Segment{text: "def", style: {:syntax, Face.new(bold: true)}}]
          }
        ]
      }

      assert HoverPopupEncoder.encode_command(model) ==
               <<@op_gui_hover_popup, 1, 0::16, 0::16, 0, 0::16, 1::16, 1, 1::16, 13, 0xBB, 0xC2,
                 0xCF, 0x01, 3::16, "def", @op_gui_hover_action, 1::16, 0>>
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
