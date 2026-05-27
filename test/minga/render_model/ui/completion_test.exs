defmodule Minga.RenderModel.UI.CompletionTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Completion

  describe "%Completion{}" do
    test "requires encoded and fingerprint" do
      model = %Completion{encoded: <<>>, fingerprint: 0}

      assert model.encoded == <<>>
      assert model.fingerprint == 0
    end

    test "raises when required fields are missing" do
      assert_raise ArgumentError, fn ->
        struct!(Completion, %{})
      end
    end

    test "accepts integer fingerprint" do
      model = %Completion{encoded: <<0x73, 1>>, fingerprint: 42}

      assert model.fingerprint == 42
    end
  end
end
