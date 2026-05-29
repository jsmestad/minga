defmodule Minga.Frontend.Adapter.GUI.SignatureHelpEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.SignatureHelpEncoder
  alias Minga.RenderModel.UI.SignatureHelp
  alias Minga.RenderModel.UI.SignatureHelp.Parameter
  alias Minga.RenderModel.UI.SignatureHelp.Signature
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

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

    test "produces byte-identical output to legacy ProtocolGUI for hidden state" do
      model = %SignatureHelp{}

      assert SignatureHelpEncoder.encode_command(model) ==
               ProtocolGUI.encode_gui_signature_help(nil)
    end

    test "produces byte-identical output to legacy ProtocolGUI for visible signature help" do
      legacy = legacy_signature_help()
      model = signature_help_model()

      assert SignatureHelpEncoder.encode_command(model) ==
               ProtocolGUI.encode_gui_signature_help(legacy)
    end

    test "clamps active indexes and counts to protocol byte fields" do
      parameters =
        for index <- 1..260 do
          %Parameter{label: "param-#{index}", documentation: "doc-#{index}"}
        end

      signatures =
        for index <- 1..260 do
          %Signature{label: "sig-#{index}", documentation: "doc-#{index}", parameters: parameters}
        end

      model = %SignatureHelp{
        visible?: true,
        anchor_row: 4,
        anchor_col: 9,
        active_signature: 300,
        active_parameter: 300,
        signatures: signatures
      }

      <<@op_gui_signature_help, 1, 4::16, 9::16, active_signature::8, active_parameter::8,
        signature_count::8, first_signature::binary>> = SignatureHelpEncoder.encode_command(model)

      <<label_len::16, _label::binary-size(label_len), doc_len::16, _doc::binary-size(doc_len),
        parameter_count::8, _rest::binary>> = first_signature

      assert active_signature == 254
      assert active_parameter == 254
      assert signature_count == 255
      assert parameter_count == 255
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

  defp legacy_signature_help do
    %MingaEditor.SignatureHelp{
      signatures: [
        %{
          label: "foo(a, b)",
          documentation: "Does foo things",
          parameters: [
            %{label: "a", documentation: "first"},
            %{label: "b", documentation: "second"}
          ]
        }
      ],
      active_signature: 0,
      active_parameter: 1,
      anchor_row: 10,
      anchor_col: 5
    }
  end
end
