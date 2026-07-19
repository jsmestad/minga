defmodule Minga.Frontend.Adapter.GUI.SignatureHelpEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.EncodingError
  alias Minga.Frontend.Adapter.GUI.SignatureHelpEncoder
  alias Minga.RenderModel.UI.SignatureHelp
  alias Minga.RenderModel.UI.SignatureHelp.Parameter
  alias Minga.RenderModel.UI.SignatureHelp.Signature

  @op_gui_signature_help Minga.Protocol.Opcodes.gui_signature_help()

  describe "encode/2" do
    test "encodes hidden signature help" do
      model = %SignatureHelp{}
      caches = Caches.new()

      {cmd, _caches} = SignatureHelpEncoder.encode(model, caches)

      assert cmd == <<@op_gui_signature_help, 0::8>>
    end

    test "returns nil on second call with same fingerprint" do
      model = %SignatureHelp{}
      caches = Caches.new()

      {cmd1, caches} = SignatureHelpEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = SignatureHelpEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when semantic fields change" do
      model1 = %SignatureHelp{}
      model2 = signature_help_model()

      caches = Caches.new()
      {_, caches} = SignatureHelpEncoder.encode(model1, caches)
      {cmd2, _caches} = SignatureHelpEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == SignatureHelpEncoder.encode_command(model2)
    end

    test "encodes hidden signature help command directly" do
      assert SignatureHelpEncoder.encode_command(%SignatureHelp{}) ==
               <<@op_gui_signature_help, 0::8>>
    end

    test "encodes visible signature help command directly" do
      assert SignatureHelpEncoder.encode_command(signature_help_model()) ==
               <<@op_gui_signature_help, 1, 10::16, 5::16, 0, 1, 1, 9::16, "foo(a, b)", 15::16,
                 "Does foo things", 2, 1::16, "a", 5::16, "first", 1::16, "b", 6::16, "second">>
    end

    test "raises instead of clamping active indexes to protocol byte fields" do
      model = %SignatureHelp{
        visible?: true,
        anchor_row: 4,
        anchor_col: 9,
        active_signature: 256,
        active_parameter: 0,
        signatures: []
      }

      assert_raise EncodingError,
                   "cannot encode gui_signature_help.active_signature=256; expected 0..255",
                   fn -> SignatureHelpEncoder.encode_command(model) end
    end
  end

  defp signature_help_model do
    %SignatureHelp{
      visible?: true,
      anchor_row: 10,
      anchor_col: 5,
      active_signature: 0,
      active_parameter: 1,
      signatures: [
        %Signature{
          label: "foo(a, b)",
          documentation: "Does foo things",
          parameters: [
            %Parameter{label: "a", documentation: "first"},
            %Parameter{label: "b", documentation: "second"}
          ]
        }
      ]
    }
  end
end
