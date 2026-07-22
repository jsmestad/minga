defmodule MingaEditor.Frontend.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Frontend.ResourcePolicy

  describe "query helpers" do
    test "gui?/1" do
      refute Capabilities.gui?(%Capabilities{frontend_type: :tui})
      assert Capabilities.gui?(%Capabilities{frontend_type: :native_gui})
      refute Capabilities.gui?(%Capabilities{frontend_type: :web})
    end

    test "semantic_ui?/1" do
      refute Capabilities.semantic_ui?(%Capabilities{})
      assert Capabilities.semantic_ui?(%Capabilities{semantic_ui: true})
    end

    test "width_oracle/1 returns the safe production oracle" do
      assert %Minga.Core.WidthOracle.Monospace{} =
               Capabilities.width_oracle(%Capabilities{text_rendering: :monospace})

      assert %Minga.Core.WidthOracle.Monospace{} =
               Capabilities.width_oracle(%Capabilities{text_rendering: :proportional})
    end
  end

  describe "resource policy" do
    test "only non-zero dimensions on a versioned policy are advertised" do
      policy = ResourcePolicy.new(1, 64_000, 0, 0)

      assert ResourcePolicy.advertised?(policy, :frame_bytes)
      refute ResourcePolicy.advertised?(policy, :frame_commands)
      refute ResourcePolicy.advertised?(policy, :window_rows)
      refute ResourcePolicy.advertised?(ResourcePolicy.new(0, 64_000, 0, 0), :frame_bytes)
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
      assert caps.text_rendering == :proportional
      refute caps.semantic_ui
    end

    test "decodes 7-byte capability payload with semantic UI flag" do
      binary = <<0, 2, 1, 0, 0, 0, 1>>
      caps = Capabilities.from_binary(binary)
      assert caps.frontend_type == :tui
      assert caps.color_depth == :rgb
      assert caps.unicode_width == :unicode_15
      assert caps.semantic_ui
      assert caps.resource_policy == ResourcePolicy.unadvertised()
    end

    test "preserves frontend_type byte 2 as web until a protocol bump" do
      caps = Capabilities.from_binary(<<2, 2, 1, 0, 0, 0, 1>>)

      assert caps.frontend_type == :web
      refute Capabilities.gui?(caps)
    end

    test "decodes capability-format-2 resource policy fields" do
      binary = <<1, 2, 1, 0, 1, 1, 1, 1, 64_000::32, 4_000::32, 800::32>>
      caps = Capabilities.from_binary(binary, 2)

      assert caps.frontend_type == :native_gui
      assert caps.semantic_ui

      assert caps.resource_policy == %ResourcePolicy{
               version: 1,
               max_frame_bytes: 64_000,
               max_frame_commands: 4_000,
               max_window_rows: 800
             }
    end

    test "does not interpret a format-2 tail under a legacy format version" do
      binary = <<0, 2, 1, 0, 0, 0, 1, 1, 64_000::32, 4_000::32, 800::32>>
      assert Capabilities.from_binary(binary, 1) == Capabilities.default()
    end

    test "returns defaults for invalid binary" do
      caps = Capabilities.from_binary(<<>>)
      assert caps == Capabilities.default()
    end
  end
end
