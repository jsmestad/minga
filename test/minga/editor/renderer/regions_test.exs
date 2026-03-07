defmodule Minga.Editor.Renderer.RegionsTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.Layout
  alias Minga.Editor.Renderer.Regions


  describe "define_regions/1" do
    test "generates minibuffer region for minimal layout" do
      layout = %Layout{
        terminal: {0, 0, 80, 24},
        editor_area: {0, 0, 80, 23},
        minibuffer: {23, 0, 80, 1},
        window_layouts: %{
          1 => %{
            total: {0, 0, 80, 23},
            content: {0, 0, 80, 22},
            modeline: {22, 0, 80, 1}
          }
        }
      }

      commands = Regions.define_regions(layout)

      # Should have: minibuffer (1) + window content (1) + window modeline (1) = 3
      assert length(commands) == 3

      # All commands should be valid define_region binaries (opcode 0x14)
      for cmd <- commands do
        assert <<0x14, _rest::binary>> = cmd
      end
    end

    test "includes file tree region when present" do
      layout = %Layout{
        terminal: {0, 0, 80, 24},
        editor_area: {0, 31, 49, 23},
        file_tree: {0, 0, 30, 23},
        minibuffer: {23, 0, 80, 1},
        window_layouts: %{
          1 => %{
            total: {0, 31, 49, 23},
            content: {0, 31, 49, 22},
            modeline: {22, 31, 49, 1}
          }
        }
      }

      commands = Regions.define_regions(layout)
      # file_tree (1) + minibuffer (1) + window content (1) + modeline (1) = 4
      assert length(commands) == 4
    end

    test "includes agent panel region when present" do
      layout = %Layout{
        terminal: {0, 0, 80, 24},
        editor_area: {0, 0, 80, 15},
        agent_panel: {15, 0, 80, 8},
        minibuffer: {23, 0, 80, 1},
        window_layouts: %{
          1 => %{
            total: {0, 0, 80, 15},
            content: {0, 0, 80, 14},
            modeline: {14, 0, 80, 1}
          }
        }
      }

      commands = Regions.define_regions(layout)
      # minibuffer (1) + agent_panel (1) + window content (1) + modeline (1) = 4
      assert length(commands) == 4
    end

    test "generates regions for multiple windows in split" do
      layout = %Layout{
        terminal: {0, 0, 80, 24},
        editor_area: {0, 0, 80, 23},
        minibuffer: {23, 0, 80, 1},
        window_layouts: %{
          1 => %{
            total: {0, 0, 39, 23},
            content: {0, 0, 39, 22},
            modeline: {22, 0, 39, 1}
          },
          2 => %{
            total: {0, 40, 40, 23},
            content: {0, 40, 40, 22},
            modeline: {22, 40, 40, 1}
          }
        }
      }

      commands = Regions.define_regions(layout)
      # minibuffer (1) + 2 windows × (content + modeline) = 5
      assert length(commands) == 5
    end

    test "skips zero-height modelines" do
      layout = %Layout{
        terminal: {0, 0, 80, 24},
        editor_area: {0, 0, 80, 23},
        minibuffer: {23, 0, 80, 1},
        window_layouts: %{
          1 => %{
            total: {0, 0, 80, 1},
            content: {0, 0, 80, 1},
            modeline: {1, 0, 80, 0}
          }
        }
      }

      commands = Regions.define_regions(layout)
      # minibuffer (1) + window content only (1) = 2 (no modeline)
      assert length(commands) == 2
    end
  end

  describe "region IDs" do
    test "window_region_id uses 100+ base" do
      assert Regions.window_region_id(1) == 101
      assert Regions.window_region_id(5) == 105
    end

    test "modeline_region_id uses 200+ base" do
      assert Regions.modeline_region_id(1) == 201
      assert Regions.modeline_region_id(5) == 205
    end
  end

  describe "round-trip with Protocol decoder" do
    test "region commands are valid define_region binaries" do
      layout = %Layout{
        terminal: {0, 0, 80, 24},
        editor_area: {0, 0, 80, 23},
        minibuffer: {23, 0, 80, 1},
        window_layouts: %{
          1 => %{
            total: {0, 0, 80, 23},
            content: {0, 0, 80, 22},
            modeline: {22, 0, 80, 1}
          }
        }
      }

      commands = Regions.define_regions(layout)

      for cmd <- commands do
        # Each command starts with define_region opcode (0x14)
        # and has the right size: 1 + 2 + 2 + 1 + 2 + 2 + 2 + 2 + 1 = 15 bytes
        assert byte_size(cmd) == 15
        assert <<0x14, _id::16, _parent::16, _role::8, _row::16, _col::16, _w::16, _h::16, _z::8>> = cmd
      end
    end
  end
end
