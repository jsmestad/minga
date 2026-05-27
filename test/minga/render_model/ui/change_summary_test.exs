defmodule Minga.RenderModel.UI.ChangeSummaryTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.ChangeSummary

  describe "%ChangeSummary{}" do
    test "requires encoded and fingerprint" do
      model = %ChangeSummary{encoded: <<>>, fingerprint: :hidden}

      assert model.encoded == <<>>
      assert model.fingerprint == :hidden
    end

    test "raises when required fields are missing" do
      assert_raise ArgumentError, fn ->
        struct!(ChangeSummary, %{})
      end
    end

    test "accepts visible state with integer fingerprint" do
      model = %ChangeSummary{encoded: <<0x89, 1>>, fingerprint: 42}

      assert model.fingerprint == 42
    end
  end
end
