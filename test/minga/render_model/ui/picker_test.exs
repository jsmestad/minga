defmodule Minga.RenderModel.UI.PickerTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Picker

  describe "%Picker{}" do
    test "requires encoded and fingerprint" do
      model = %Picker{encoded: <<>>, fingerprint: :closed}

      assert model.encoded == <<>>
      assert model.fingerprint == :closed
    end

    test "raises when required fields are missing" do
      assert_raise ArgumentError, fn ->
        struct!(Picker, %{})
      end
    end

    test "accepts open state with integer fingerprint" do
      model = %Picker{encoded: <<0x77, 1>>, fingerprint: 12345}

      assert model.fingerprint == 12345
    end
  end
end
