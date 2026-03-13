defmodule Minga.Picker.ExtensionSourceTest do
  use ExUnit.Case, async: true

  alias Minga.Picker.ExtensionSource

  describe "title/0" do
    test "returns Extension" do
      assert ExtensionSource.title() == "Extension"
    end
  end

  describe "on_cancel/1" do
    test "returns state unchanged" do
      state = %{foo: :bar}
      assert ExtensionSource.on_cancel(state) == state
    end
  end
end
