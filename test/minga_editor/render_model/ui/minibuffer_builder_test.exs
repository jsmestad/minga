defmodule MingaEditor.RenderModel.UI.MinibufferBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.MinibufferBuilder
  alias Minga.RenderModel.UI.Minibuffer
  alias MingaEditor.MinibufferData

  @op_gui_minibuffer Minga.Protocol.Opcodes.gui_minibuffer()

  describe "build/1" do
    test "builds hidden minibuffer when data is nil" do
      model = MinibufferBuilder.build(nil)

      assert %Minibuffer{fingerprint: :hidden} = model
      assert is_binary(model.encoded)
      assert <<@op_gui_minibuffer, 0::8>> = model.encoded
    end

    test "builds hidden minibuffer when visible is false" do
      data = %MinibufferData{visible: false}
      model = MinibufferBuilder.build(data)

      assert %Minibuffer{fingerprint: :hidden} = model
      assert <<@op_gui_minibuffer, 0::8>> = model.encoded
    end

    test "builds visible minibuffer" do
      data = %MinibufferData{
        visible: true,
        mode: 0,
        cursor_pos: 3,
        prompt: ":",
        input: "wq",
        context: "",
        selected_index: 0,
        candidates: [],
        total_candidates: 0
      }

      model = MinibufferBuilder.build(data)

      assert %Minibuffer{} = model
      assert model.fingerprint != :hidden
      assert is_binary(model.encoded)
      assert <<@op_gui_minibuffer, _rest::binary>> = model.encoded
    end

    test "fingerprint changes when input changes" do
      base = %MinibufferData{
        visible: true,
        mode: 0,
        cursor_pos: 3,
        prompt: ":",
        input: "wq",
        context: "",
        selected_index: 0,
        candidates: [],
        total_candidates: 0
      }

      model1 = MinibufferBuilder.build(base)
      model2 = MinibufferBuilder.build(%{base | input: "q!"})

      assert model1.fingerprint != model2.fingerprint
    end

    test "produces byte-identical output to legacy for hidden state" do
      alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

      legacy_binary = ProtocolGUI.encode_gui_minibuffer(%MinibufferData{visible: false})

      model = MinibufferBuilder.build(nil)

      assert model.encoded == legacy_binary,
             "Hidden minibuffer: new builder output does not match legacy output"
    end

    test "produces byte-identical output to legacy for visible state" do
      alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

      data = %MinibufferData{
        visible: true,
        mode: 0,
        cursor_pos: 5,
        prompt: ":",
        input: "hello",
        context: "test",
        selected_index: 0,
        candidates: [],
        total_candidates: 0
      }

      legacy_binary = ProtocolGUI.encode_gui_minibuffer(data)
      model = MinibufferBuilder.build(data)

      assert model.encoded == legacy_binary,
             "Visible minibuffer: new builder output does not match legacy output"
    end
  end
end
