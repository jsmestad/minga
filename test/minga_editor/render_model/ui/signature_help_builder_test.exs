defmodule MingaEditor.RenderModel.UI.SignatureHelpBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.SignatureHelp
  alias Minga.RenderModel.UI.SignatureHelp.Parameter
  alias Minga.RenderModel.UI.SignatureHelp.Signature
  alias MingaEditor.RenderModel.UI.SignatureHelpBuilder

  describe "build/1" do
    test "builds hidden signature help when no shell_state exists" do
      model = SignatureHelpBuilder.build(%{})

      assert %SignatureHelp{} = model
      refute model.visible?
      assert model.signatures == []
    end

    test "builds hidden signature help when signature_help is nil" do
      model = SignatureHelpBuilder.build(%{shell_state: %{signature_help: nil}})

      refute model.visible?
      assert model.signatures == []
    end

    test "builds hidden signature help for empty signatures" do
      sh = %MingaEditor.SignatureHelp{
        signatures: [],
        active_signature: 0,
        active_parameter: 0,
        anchor_row: 0,
        anchor_col: 0
      }

      model = SignatureHelpBuilder.build(%{shell_state: %{signature_help: sh}})

      refute model.visible?
      assert model.signatures == []
    end

    test "builds semantic visible signature help" do
      sh = signature_help()

      model = SignatureHelpBuilder.build(%{shell_state: %{signature_help: sh}})

      assert model.visible?
      assert model.anchor_row == 10
      assert model.anchor_col == 5
      assert model.active_signature == 0
      assert model.active_parameter == 1

      assert [
               %Signature{
                 label: "foo(a, b)",
                 documentation: "Does foo things",
                 parameters: [
                   %Parameter{label: "a", documentation: "first"},
                   %Parameter{label: "b", documentation: "second"}
                 ]
               }
             ] = model.signatures
    end
  end

  defp signature_help do
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
