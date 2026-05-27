defmodule Minga.RenderModel.UI.SidebarsTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Sidebars

  describe "%Sidebars{}" do
    test "defaults to nil encoded and nil fingerprint" do
      sidebars = %Sidebars{}

      assert sidebars.encoded == nil
      assert sidebars.fingerprint == nil
    end

    test "accepts binary encoded and integer fingerprint" do
      sidebars = %Sidebars{encoded: <<0x9F, 0, 0, 0, 5, "data">>, fingerprint: 12345}

      assert sidebars.encoded == <<0x9F, 0, 0, 0, 5, "data">>
      assert sidebars.fingerprint == 12345
    end
  end
end
