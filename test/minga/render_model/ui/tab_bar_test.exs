defmodule Minga.RenderModel.UI.TabBarTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.TabBar

  describe "%TabBar{}" do
    test "defaults to nil encoded and suppressed fingerprint" do
      tab_bar = %TabBar{}

      assert tab_bar.encoded == nil
      assert tab_bar.fingerprint == :suppressed
    end

    test "accepts binary encoded and integer fingerprint" do
      tab_bar = %TabBar{encoded: <<0x71, 0, 1>>, fingerprint: 12345}

      assert tab_bar.encoded == <<0x71, 0, 1>>
      assert tab_bar.fingerprint == 12345
    end

    test "accepts suppressed fingerprint with nil encoded" do
      tab_bar = %TabBar{encoded: nil, fingerprint: :suppressed}

      assert tab_bar.encoded == nil
      assert tab_bar.fingerprint == :suppressed
    end
  end
end
