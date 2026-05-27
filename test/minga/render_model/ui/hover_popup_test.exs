defmodule Minga.RenderModel.UI.HoverPopupTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.HoverPopup

  describe "%HoverPopup{}" do
    test "requires encoded and fingerprint" do
      model = %HoverPopup{encoded: <<>>, fingerprint: 12345}

      assert model.encoded == <<>>
      assert model.fingerprint == 12345
    end

    test "raises when required fields are missing" do
      assert_raise ArgumentError, fn ->
        struct!(HoverPopup, %{})
      end
    end

    test "accepts integer fingerprint" do
      model = %HoverPopup{encoded: <<0x81, 0>>, fingerprint: 99999}

      assert model.fingerprint == 99999
    end
  end
end
