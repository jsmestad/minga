defmodule Minga.RenderModel.UI.ObservatoryTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Observatory

  describe "%Observatory{}" do
    test "requires visible, encoded, and fingerprint" do
      obs = %Observatory{visible: false, encoded: <<>>, fingerprint: :hidden}

      assert obs.visible == false
      assert obs.encoded == <<>>
      assert obs.fingerprint == :hidden
    end

    test "raises when required fields are missing" do
      assert_raise ArgumentError, fn ->
        struct!(Observatory, %{})
      end
    end

    test "accepts visible state with integer fingerprint" do
      obs = %Observatory{visible: true, encoded: <<0x9A, 0>>, fingerprint: 12_345}

      assert obs.visible == true
      assert obs.fingerprint == 12_345
    end
  end
end
