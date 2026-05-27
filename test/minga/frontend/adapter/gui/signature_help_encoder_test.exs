defmodule Minga.Frontend.Adapter.GUI.SignatureHelpEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.SignatureHelpEncoder
  alias Minga.RenderModel.UI.SignatureHelp

  @op_gui_signature_help Minga.Protocol.Opcodes.gui_signature_help()

  describe "encode/2" do
    test "encodes signature help" do
      model = %SignatureHelp{
        encoded: <<@op_gui_signature_help, 0::8>>,
        fingerprint: 12_345
      }

      caches = Caches.new()

      {cmd, _caches} = SignatureHelpEncoder.encode(model, caches)

      assert cmd == model.encoded
    end

    test "returns nil on second call with same fingerprint" do
      model = %SignatureHelp{
        encoded: <<@op_gui_signature_help, 0::8>>,
        fingerprint: 12_345
      }

      caches = Caches.new()

      {cmd1, caches} = SignatureHelpEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = SignatureHelpEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when fingerprint changes" do
      model1 = %SignatureHelp{
        encoded: <<@op_gui_signature_help, 0::8>>,
        fingerprint: 11_111
      }

      model2 = %SignatureHelp{
        encoded: <<@op_gui_signature_help, 1::8, "sigs">>,
        fingerprint: 22_222
      }

      caches = Caches.new()
      {_, caches} = SignatureHelpEncoder.encode(model1, caches)
      {cmd2, _caches} = SignatureHelpEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == model2.encoded
    end
  end
end
