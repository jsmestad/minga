defmodule Minga.RenderModel.UI.FloatPopupTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.FloatPopup

  describe "%FloatPopup{}" do
    test "requires encoded and fingerprint" do
      model = %FloatPopup{encoded: <<>>, fingerprint: 12_345}

      assert model.encoded == <<>>
      assert model.fingerprint == 12_345
    end

    test "raises when required fields are missing" do
      assert_raise ArgumentError, fn ->
        struct!(FloatPopup, %{})
      end
    end

    test "accepts integer fingerprint" do
      model = %FloatPopup{encoded: <<0x83, 0>>, fingerprint: 99_999}

      assert model.fingerprint == 99_999
    end
  end
end
