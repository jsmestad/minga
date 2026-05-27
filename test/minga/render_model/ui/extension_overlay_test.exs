defmodule Minga.RenderModel.UI.ExtensionOverlayTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.ExtensionOverlay

  describe "%ExtensionOverlay{}" do
    test "requires encoded and fingerprint" do
      model = %ExtensionOverlay{encoded: <<>>, fingerprint: 12_345}

      assert model.encoded == <<>>
      assert model.fingerprint == 12_345
    end

    test "raises when required fields are missing" do
      assert_raise ArgumentError, fn ->
        struct!(ExtensionOverlay, %{})
      end
    end

    test "accepts integer fingerprint" do
      model = %ExtensionOverlay{encoded: <<0x9C, 0::16, 0>>, fingerprint: 99_999}

      assert model.fingerprint == 99_999
    end
  end
end
