defmodule MingaEditor.Frontend.GUIHoverProtocolTest do
  @moduledoc """
  Tests for retained GUI split separator protocol encoding.
  """

  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.SplitSeparatorsEncoder
  alias Minga.RenderModel.UI.SplitSeparators

  # ── Split Separators ──────────────────────────────────────────────

  @op_gui_split_separators 0x84

  describe "SplitSeparatorsEncoder.encode/2" do
    test "empty separators encode correctly" do
      {result, _caches} =
        SplitSeparatorsEncoder.encode(
          %SplitSeparators{border_color_rgb: 0x5B6268, verticals: [], horizontals: []},
          Caches.new()
        )

      assert <<@op_gui_split_separators, 0x5B, 0x62, 0x68, 0, 0>> = result
    end

    test "vertical separators encode correctly" do
      verticals = [{10, 0, 24}]

      {result, _caches} =
        SplitSeparatorsEncoder.encode(
          %SplitSeparators{border_color_rgb: 0xABCDEF, verticals: verticals, horizontals: []},
          Caches.new()
        )

      assert <<@op_gui_split_separators, 0xAB, 0xCD, 0xEF, 1, 10::16, 0::16, 24::16, 0>> =
               result
    end

    test "horizontal separators with filename encode correctly" do
      horizontals = [{12, 0, 80, "editor.ex"}]

      {result, _caches} =
        SplitSeparatorsEncoder.encode(
          %SplitSeparators{border_color_rgb: 0x333333, verticals: [], horizontals: horizontals},
          Caches.new()
        )

      assert <<@op_gui_split_separators, 0x33, 0x33, 0x33, 0, 1, 12::16, 0::16, 80::16, 9::16,
               "editor.ex">> = result
    end

    test "mixed vertical and horizontal separators" do
      verticals = [{40, 0, 30}, {80, 0, 30}]
      horizontals = [{15, 0, 40, "foo.ex"}]

      {result, _caches} =
        SplitSeparatorsEncoder.encode(
          %SplitSeparators{
            border_color_rgb: 0x555555,
            verticals: verticals,
            horizontals: horizontals
          },
          Caches.new()
        )

      # Header: opcode + color(3) + vert_count(1)
      assert <<@op_gui_split_separators, 0x55, 0x55, 0x55, 2, rest::binary>> = result
      # Two vertical entries (6 bytes each) + horiz_count(1) + horizontal data
      assert <<40::16, 0::16, 30::16, 80::16, 0::16, 30::16, 1, _horiz::binary>> = rest
    end
  end
end
