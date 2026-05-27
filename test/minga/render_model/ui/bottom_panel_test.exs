defmodule Minga.RenderModel.UI.BottomPanelTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.BottomPanel

  describe "%BottomPanel{}" do
    test "requires encoded and fingerprint" do
      model = %BottomPanel{encoded: <<>>, fingerprint: 0}

      assert model.encoded == <<>>
      assert model.fingerprint == 0
    end

    test "raises when required fields are missing" do
      assert_raise ArgumentError, fn ->
        struct!(BottomPanel, %{})
      end
    end
  end
end
