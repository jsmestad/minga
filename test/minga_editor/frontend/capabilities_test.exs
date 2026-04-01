defmodule MingaEditor.Frontend.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Capabilities

  describe "query helpers" do
    test "images?/1" do
      refute Capabilities.images?(%Capabilities{image_support: :none})
      assert Capabilities.images?(%Capabilities{image_support: :kitty})
      assert Capabilities.images?(%Capabilities{image_support: :sixel})
      assert Capabilities.images?(%Capabilities{image_support: :native})
    end

    test "native_floats?/1" do
      refute Capabilities.native_floats?(%Capabilities{float_support: :emulated})
      assert Capabilities.native_floats?(%Capabilities{float_support: :native})
    end

    test "rgb?/1" do
      assert Capabilities.rgb?(%Capabilities{color_depth: :rgb})
      refute Capabilities.rgb?(%Capabilities{color_depth: :color_256})
      refute Capabilities.rgb?(%Capabilities{color_depth: :mono})
    end

    test "gui?/1" do
      refute Capabilities.gui?(%Capabilities{frontend_type: :tui})
      assert Capabilities.gui?(%Capabilities{frontend_type: :native_gui})
      refute Capabilities.gui?(%Capabilities{frontend_type: :web})
    end
  end

  describe "from_binary/1" do
    test "decodes 6-byte capability payload" do
      # native_gui, color_256, unicode_15, kitty, native_float, proportional
      binary = <<1, 1, 1, 1, 1, 1>>
      caps = Capabilities.from_binary(binary)
      assert caps.frontend_type == :native_gui
      assert caps.color_depth == :color_256
      assert caps.unicode_width == :unicode_15
      assert caps.image_support == :kitty
      assert caps.float_support == :native
    end

    test "returns defaults for invalid binary" do
      caps = Capabilities.from_binary(<<>>)
      assert caps == Capabilities.default()
    end
  end
end
