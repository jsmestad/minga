defmodule Minga.Frontend.Adapter.GUI.CompletionEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.CompletionEncoder
  alias Minga.RenderModel.UI.Completion

  @op_gui_completion Minga.Protocol.Opcodes.gui_completion()

  describe "encode/2" do
    test "encodes completion" do
      model = %Completion{
        encoded: <<@op_gui_completion, 0::8>>,
        fingerprint: 12345
      }

      caches = Caches.new()

      {cmd, _caches} = CompletionEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "returns nil on second call with same fingerprint" do
      model = %Completion{
        encoded: <<@op_gui_completion, 0::8>>,
        fingerprint: 12345
      }

      caches = Caches.new()

      {cmd1, caches} = CompletionEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = CompletionEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when fingerprint changes" do
      model1 = %Completion{
        encoded: <<@op_gui_completion, 0::8>>,
        fingerprint: 11111
      }

      model2 = %Completion{
        encoded: <<@op_gui_completion, 1::8, "items">>,
        fingerprint: 22222
      }

      caches = Caches.new()
      {_, caches} = CompletionEncoder.encode(model1, caches)
      {cmd2, _caches} = CompletionEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == model2.encoded
    end
  end
end
