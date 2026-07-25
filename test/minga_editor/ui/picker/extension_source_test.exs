defmodule MingaEditor.UI.Picker.ExtensionSourceTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Picker.ExtensionSource

  describe "title/0" do
    test "returns Extension" do
      assert ExtensionSource.title() == "Extension"
    end
  end
end
