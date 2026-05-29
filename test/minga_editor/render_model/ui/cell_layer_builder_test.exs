defmodule MingaEditor.RenderModel.UI.CellLayerBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Face
  alias Minga.RenderModel.UI.CellLayer
  alias MingaEditor.DisplayList
  alias MingaEditor.DisplayList.{Cursor, Frame, WindowFrame}
  alias MingaEditor.RenderModel.UI.CellLayerBuilder
  alias MingaEditor.RenderPipeline.Chrome

  test "builds ordered TUI cell layers from chrome and frame compatibility data" do
    face = Face.new(fg: 0xBBC2CF, bg: 0x282C34)

    chrome = %Chrome{
      tab_bar: [DisplayList.draw(0, 0, "tabs", face)],
      file_tree: [DisplayList.draw(1, 0, "tree", face)],
      separators: [DisplayList.draw(2, 0, "sep", face)],
      status_bar_draws: [DisplayList.draw(3, 0, "status", face)],
      agent_panel: [DisplayList.draw(4, 0, "agent", face)],
      minibuffer: [DisplayList.draw(5, 0, "mini", face)],
      overlays: [%DisplayList.Overlay{draws: [DisplayList.draw(6, 0, "hover", face)]}]
    }

    frame = %Frame{
      cursor: Cursor.new(0, 0, :block),
      splash: [DisplayList.draw(7, 0, "splash", face)],
      agentic_view: [DisplayList.draw(8, 0, "agentic", face)],
      windows: [
        %WindowFrame{
          rect: {0, 0, 10, 2},
          lines: DisplayList.draws_to_layer([DisplayList.draw(9, 0, "prompt", face)]),
          window_model: %{content_kind: :agent_chat}
        }
      ]
    }

    assert %CellLayer{} = layer = CellLayerBuilder.build(frame, chrome)

    assert Enum.map(layer.pre_window_cells, & &1.text) == ["tabs", "tree", "agentic"]
    assert Enum.map(layer.legacy_window_cells, & &1.text) == ["prompt"]

    assert Enum.map(layer.post_window_cells, & &1.text) == [
             "sep",
             "status",
             "agent",
             "mini",
             "splash"
           ]

    assert Enum.map(layer.overlay_cells, & &1.text) == ["hover"]
  end

  test "excludes semantic buffer windows from legacy compatibility cells" do
    face = Face.new(fg: 0xBBC2CF, bg: 0x282C34)

    frame = %Frame{
      cursor: Cursor.new(0, 0, :block),
      windows: [
        %WindowFrame{
          rect: {0, 0, 10, 2},
          lines: DisplayList.draws_to_layer([DisplayList.draw(0, 0, "buffer", face)]),
          window_model: %{content_kind: :buffer}
        }
      ]
    }

    assert %CellLayer{} = layer = CellLayerBuilder.build(frame, %Chrome{})
    assert layer.legacy_window_cells == []
  end
end
