defmodule Minga.Frontend.Adapter.GUI.FloatPopupEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.FloatPopupEncoder
  alias Minga.RenderModel.UI.FloatPopup

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

    test "encodes hidden command bytes directly" do
      assert FloatPopupEncoder.encode_command(%FloatPopup{}) == <<@op_gui_float_popup, 0>>
    end

    test "encodes visible command bytes directly" do
      model = %FloatPopup{
        visible?: true,
        title: "Inspect",
        lines: ["line1", "line2"],
        width: 40,
        height: 20
      }

      assert FloatPopupEncoder.encode_command(model) ==
               <<@op_gui_float_popup, 1, 40::16, 20::16, 7::16, "Inspect", 2::16, 5::16, "line1",
                 5::16, "line2">>
    end

    test "encodes visible command bytes with empty title directly" do
      model = %FloatPopup{
        visible?: true,
        title: "",
        lines: ["hello"],
        width: 40,
        height: 10
      }

      assert FloatPopupEncoder.encode_command(model) ==
               <<@op_gui_float_popup, 1, 40::16, 10::16, 0::16, 1::16, 5::16, "hello">>
    end
  end
end
