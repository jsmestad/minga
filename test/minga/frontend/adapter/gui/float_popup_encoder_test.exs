defmodule Minga.Frontend.Adapter.GUI.FloatPopupEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.FloatPopupEncoder
  alias Minga.RenderModel.UI.FloatPopup
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @op_gui_float_popup Minga.Protocol.Opcodes.gui_float_popup()

  describe "encode/2" do
    test "encodes hidden float popup" do
      model = %FloatPopup{}
      caches = Caches.new()

      {cmd, _caches} = FloatPopupEncoder.encode(model, caches)

      assert cmd == <<@op_gui_float_popup, 0>>
    end

    test "returns nil on second call with same fingerprint" do
      model = %FloatPopup{}
      caches = Caches.new()

      {cmd1, caches} = FloatPopupEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = FloatPopupEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when semantic fields change" do
      model1 = %FloatPopup{}

      model2 = %FloatPopup{
        visible?: true,
        title: "Inspect",
        lines: ["line1"],
        width: 40,
        height: 20
      }

      caches = Caches.new()
      {_, caches} = FloatPopupEncoder.encode(model1, caches)
      {cmd2, _caches} = FloatPopupEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == FloatPopupEncoder.encode_command(model2)
    end

    test "produces byte-identical output to legacy ProtocolGUI for hidden state" do
      legacy = %{visible: false, title: "", lines: [], width: 0, height: 0}

      assert FloatPopupEncoder.encode_command(%FloatPopup{}) ==
               ProtocolGUI.encode_gui_float_popup(legacy)
    end

    test "produces byte-identical output to legacy ProtocolGUI for visible popup" do
      data = %{visible: true, title: "Inspect", lines: ["line1", "line2"], width: 40, height: 20}

      model = %FloatPopup{
        visible?: true,
        title: "Inspect",
        lines: ["line1", "line2"],
        width: 40,
        height: 20
      }

      assert FloatPopupEncoder.encode_command(model) == ProtocolGUI.encode_gui_float_popup(data)
    end
  end
end
