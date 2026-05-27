defmodule Minga.Frontend.Adapter.GUI.MinibufferEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.MinibufferEncoder
  alias Minga.RenderModel.UI.Minibuffer

  @op_gui_minibuffer Minga.Protocol.Opcodes.gui_minibuffer()

  describe "encode/2" do
    test "encodes hidden minibuffer" do
      model = %Minibuffer{
        encoded: <<@op_gui_minibuffer, 0::8>>,
        fingerprint: :hidden
      }

      caches = Caches.new()

      {cmd, _caches} = MinibufferEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "encodes visible minibuffer" do
      model = %Minibuffer{
        encoded: <<@op_gui_minibuffer, 1::8, "data">>,
        fingerprint: {true, :ex, 5, ":", "input", "", 0, 0, 0, []}
      }

      caches = Caches.new()

      {cmd, _caches} = MinibufferEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "returns nil on second call with same fingerprint" do
      model = %Minibuffer{
        encoded: <<@op_gui_minibuffer, 0::8>>,
        fingerprint: :hidden
      }

      caches = Caches.new()

      {cmd1, caches} = MinibufferEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = MinibufferEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when fingerprint changes" do
      model1 = %Minibuffer{
        encoded: <<@op_gui_minibuffer, 0::8>>,
        fingerprint: :hidden
      }

      model2 = %Minibuffer{
        encoded: <<@op_gui_minibuffer, 1::8, "visible">>,
        fingerprint: {true, :ex, 5, ":", "text", "", 0, 0, 0, []}
      }

      caches = Caches.new()
      {_, caches} = MinibufferEncoder.encode(model1, caches)
      {cmd2, _caches} = MinibufferEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == model2.encoded
    end
  end
end
