defmodule Minga.RenderModel.UI.StatusBarTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.StatusBar

  describe "%StatusBar{}" do
    test "requires encoded" do
      sb = %StatusBar{encoded: <<0x76, 0::8>>}

      assert sb.encoded == <<0x76, 0::8>>
    end

    test "raises when encoded is missing" do
      assert_raise ArgumentError, fn ->
        struct!(StatusBar, %{})
      end
    end
  end
end
