defmodule Minga.RenderModel.UI.SignatureHelpTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.SignatureHelp
  alias Minga.RenderModel.UI.SignatureHelp.Parameter
  alias Minga.RenderModel.UI.SignatureHelp.Signature

  describe "%SignatureHelp{}" do
    test "defaults to hidden" do
      model = %SignatureHelp{}

      refute model.visible?
      assert model.anchor_row == 0
      assert model.anchor_col == 0
      assert model.active_signature == 0
      assert model.active_parameter == 0
      assert model.signatures == []
    end

    test "stores semantic signatures and parameters" do
      model = %SignatureHelp{
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

      assert model.visible?

      assert [%Signature{parameters: [%Parameter{label: "a"}, %Parameter{label: "b"}]}] =
               model.signatures
    end
  end
end
