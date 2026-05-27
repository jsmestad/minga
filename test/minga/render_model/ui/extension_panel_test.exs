defmodule Minga.RenderModel.UI.ExtensionPanelTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.ExtensionPanel

  describe "%ExtensionPanel{}" do
    test "requires encoded and fingerprint" do
      model = %ExtensionPanel{encoded: <<>>, fingerprint: 12_345}

      assert model.encoded == <<>>
      assert model.fingerprint == 12_345
    end

    test "raises when required fields are missing" do
      assert_raise ArgumentError, fn ->
        struct!(ExtensionPanel, %{})
      end
    end

    test "accepts integer fingerprint" do
      model = %ExtensionPanel{encoded: <<0x9D, 0::16, 0>>, fingerprint: 99_999}

      assert model.fingerprint == 99_999
    end
  end
end
