defmodule Minga.RenderModel.UI.MinibufferTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Minibuffer

  describe "%Minibuffer{}" do
    test "requires encoded and fingerprint" do
      model = %Minibuffer{encoded: <<>>, fingerprint: :hidden}

      assert model.encoded == <<>>
      assert model.fingerprint == :hidden
    end

    test "raises when required fields are missing" do
      assert_raise ArgumentError, fn ->
        struct!(Minibuffer, %{})
      end
    end

    test "accepts visible state with tuple fingerprint" do
      model = %Minibuffer{encoded: <<0x7F, 1>>, fingerprint: {true, :ex, 5}}

      assert model.fingerprint == {true, :ex, 5}
    end
  end
end
