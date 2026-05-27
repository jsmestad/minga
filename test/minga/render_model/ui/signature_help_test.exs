defmodule Minga.RenderModel.UI.SignatureHelpTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.SignatureHelp

  describe "%SignatureHelp{}" do
    test "requires encoded and fingerprint" do
      model = %SignatureHelp{encoded: <<>>, fingerprint: 0}

      assert model.encoded == <<>>
      assert model.fingerprint == 0
    end

    test "raises when required fields are missing" do
      assert_raise ArgumentError, fn ->
        struct!(SignatureHelp, %{})
      end
    end
  end
end
