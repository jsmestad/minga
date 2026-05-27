defmodule MingaEditor.RenderModel.UI.SignatureHelpBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.SignatureHelpBuilder
  alias Minga.RenderModel.UI.SignatureHelp
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI

  @op_gui_signature_help Minga.Protocol.Opcodes.gui_signature_help()

  describe "build/1" do
    test "builds empty signature help when no shell_state" do
      ctx = %{}

      model = SignatureHelpBuilder.build(ctx)

      assert %SignatureHelp{} = model
      assert is_binary(model.encoded)
      assert <<@op_gui_signature_help, 0::8>> = model.encoded
    end

    test "builds empty signature help when signature_help is nil" do
      ctx = %{shell_state: %{signature_help: nil}}

      model = SignatureHelpBuilder.build(ctx)

      assert %SignatureHelp{} = model
      assert is_binary(model.encoded)
    end

    test "produces byte-identical output to legacy for nil" do
      legacy_binary = ProtocolGUI.encode_gui_signature_help(nil)

      model = SignatureHelpBuilder.build(%{shell_state: %{signature_help: nil}})

      assert model.encoded == legacy_binary,
             "Nil signature help: new builder output does not match legacy output"
    end

    test "produces byte-identical output to legacy for empty signatures" do
      sh = %MingaEditor.SignatureHelp{
        signatures: [],
        active_signature: 0,
        active_parameter: 0,
        anchor_row: 0,
        anchor_col: 0
      }

      legacy_binary = ProtocolGUI.encode_gui_signature_help(sh)

      model = SignatureHelpBuilder.build(%{shell_state: %{signature_help: sh}})

      assert model.encoded == legacy_binary,
             "Empty signatures: new builder output does not match legacy output"
    end

    test "produces byte-identical output to legacy for populated signature help" do
      sh = %MingaEditor.SignatureHelp{
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

      legacy_binary = ProtocolGUI.encode_gui_signature_help(sh)

      model = SignatureHelpBuilder.build(%{shell_state: %{signature_help: sh}})

      assert model.encoded == legacy_binary,
             "Populated signature help: new builder output does not match legacy output"
    end

    test "fingerprint changes when signature help changes" do
      sh1 = %MingaEditor.SignatureHelp{
        signatures: [],
        active_signature: 0,
        active_parameter: 0,
        anchor_row: 0,
        anchor_col: 0
      }

      sh2 = %MingaEditor.SignatureHelp{
        signatures: [],
        active_signature: 0,
        active_parameter: 1,
        anchor_row: 0,
        anchor_col: 0
      }

      model1 = SignatureHelpBuilder.build(%{shell_state: %{signature_help: sh1}})
      model2 = SignatureHelpBuilder.build(%{shell_state: %{signature_help: sh2}})

      assert model1.fingerprint != model2.fingerprint
    end
  end
end
