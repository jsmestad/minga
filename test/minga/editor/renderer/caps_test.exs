defmodule Minga.Editor.Renderer.CapsTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.Renderer.Caps
  alias Minga.Port.Capabilities

  describe "render_overlays?/1" do
    test "true for emulated floats (TUI default)" do
      assert Caps.render_overlays?(%Capabilities{float_support: :emulated})
    end

    test "false for native floats (GUI)" do
      refute Caps.render_overlays?(%Capabilities{float_support: :native})
    end
  end

  describe "measure_text_remotely?/1" do
    test "false for monospace (TUI default)" do
      refute Caps.measure_text_remotely?(%Capabilities{text_rendering: :monospace})
    end

    test "true for proportional fonts" do
      assert Caps.measure_text_remotely?(%Capabilities{text_rendering: :proportional})
    end
  end

  describe "adapt_color/2" do
    test "passes through for RGB" do
      assert Caps.adapt_color(0xFF6C6B, %Capabilities{color_depth: :rgb}) == 0xFF6C6B
    end

    test "converts to 256-color index" do
      # Red-ish color should map to a cube index
      result = Caps.adapt_color(0xFF0000, %Capabilities{color_depth: :color_256})
      assert is_integer(result)
      assert result >= 16 and result <= 231
    end

    test "grayscale colors use grayscale ramp" do
      result = Caps.adapt_color(0x808080, %Capabilities{color_depth: :color_256})
      assert result >= 232 and result <= 255
    end

    test "monochrome returns white" do
      assert Caps.adapt_color(0xFF6C6B, %Capabilities{color_depth: :mono}) == 0xFFFFFF
    end
  end

  describe "send_images?/1" do
    test "false when no image support" do
      refute Caps.send_images?(%Capabilities{image_support: :none})
    end

    test "true for kitty" do
      assert Caps.send_images?(%Capabilities{image_support: :kitty})
    end

    test "true for native" do
      assert Caps.send_images?(%Capabilities{image_support: :native})
    end
  end
end
