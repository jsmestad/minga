defmodule Minga.Frontend.Adapter.GUITest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.WindowEncoder
  alias Minga.RenderModel
  alias Minga.RenderModel.Cursor
  alias Minga.RenderModel.UI.GutterSeparator
  alias Minga.RenderModel.UI.Theme
  alias Minga.RenderModel.Window
  alias Minga.RenderModel.Window.Row
  alias Minga.Test.GUIWindowDecoder

  describe "encode/2" do
    test "encodes one render model into ordered metal and chrome command groups" do
      window = %Window{
        window_id: 1,
        content_kind: :buffer,
        rect: {0, 0, 80, 20},
        rows: [],
        cursor_row: 0,
        cursor_col: 0,
        cursor_shape: :block
      }

      ui = %RenderModel.UI{
        theme: %Theme{name: :test, color_slots: [{0x01, 0xFF0000}]},
        gutter_separator: %GutterSeparator{col: 4, color_rgb: 0x333333}
      }

      model = RenderModel.new([window], ui, Cursor.new(0, 0, :block), "Minga", 0x101010)
      encoded = GUI.encode(model, Caches.new())

      assert Enum.map(encoded.metal_commands, &opcode/1) == [
               WindowEncoder.opcode(),
               Minga.Protocol.Opcodes.gui_gutter_sep()
             ]

      assert Enum.map(encoded.chrome_commands, &opcode/1) == [Minga.Protocol.Opcodes.gui_theme()]
      assert encoded.metrics.window.row_bytes > 0
      assert encoded.metrics.metal_ui_bytes > 0
      assert encoded.metrics.chrome_bytes > 0
      assert encoded.caches.last_window_fps[1] != nil
      assert encoded.caches.last_gutter_separator_fp != nil
      assert encoded.caches.last_theme_fp != nil
    end

    test "sends overlay delta when only cursor fields change" do
      window = %Window{
        window_id: 1,
        content_kind: :buffer,
        rect: {0, 0, 80, 20},
        rows: [],
        cursor_row: 0,
        cursor_col: 0,
        cursor_shape: :block,
        content_epoch: 7,
        full_refresh: false
      }

      model = RenderModel.new([window], %RenderModel.UI{}, Cursor.new(0, 0, :block))
      first = GUI.encode(model, Caches.new())

      moved = %Window{
        window_id: 1,
        content_kind: :buffer,
        rect: {0, 0, 80, 20},
        rows: [],
        cursor_row: 1,
        cursor_col: 4,
        cursor_shape: :beam,
        content_epoch: 7,
        full_refresh: false
      }

      moved_model = RenderModel.new([moved], %RenderModel.UI{}, Cursor.new(1, 4, :beam))
      second = GUI.encode(moved_model, first.caches)

      assert Enum.map(first.metal_commands, &opcode/1) == [WindowEncoder.opcode()]

      assert Enum.map(second.metal_commands, &opcode/1) == [
               Minga.Protocol.Opcodes.gui_window_overlay_delta()
             ]
    end

    test "sends overlay keepalive for unchanged retained windows without metadata" do
      window = %Window{
        window_id: 1,
        content_kind: :buffer,
        rect: {0, 0, 80, 20},
        rows: [],
        cursor_row: 0,
        cursor_col: 0,
        cursor_shape: :block,
        content_epoch: 7,
        full_refresh: false
      }

      model = RenderModel.new([window], %RenderModel.UI{}, Cursor.new(0, 0, :block))
      first = GUI.encode(model, Caches.new())
      second = GUI.encode(model, first.caches)

      assert Enum.map(second.metal_commands, &opcode/1) == [
               Minga.Protocol.Opcodes.gui_window_overlay_delta()
             ]
    end

    test "sends full content after an overlay delta when rows change" do
      old_row = %Row{
        row_id: Row.stable_id(:normal, 0),
        row_type: :normal,
        buf_line: 0,
        text: "old",
        spans: [],
        content_hash: 1
      }

      window = %Window{
        window_id: 1,
        content_kind: :buffer,
        rect: {0, 0, 80, 20},
        rows: [old_row],
        cursor_row: 0,
        cursor_col: 0,
        cursor_shape: :block,
        content_epoch: 1,
        full_refresh: false
      }

      first =
        GUI.encode(
          RenderModel.new([window], %RenderModel.UI{}, Cursor.new(0, 0, :block)),
          Caches.new()
        )

      moved = %{window | cursor_col: 1}

      second =
        GUI.encode(
          RenderModel.new([moved], %RenderModel.UI{}, Cursor.new(0, 1, :block)),
          first.caches
        )

      new_row = %{old_row | text: "new", content_hash: 2}
      changed = %{moved | rows: [new_row], content_epoch: 2}

      third =
        GUI.encode(
          RenderModel.new([changed], %RenderModel.UI{}, Cursor.new(0, 1, :block)),
          second.caches
        )

      assert Enum.map(second.metal_commands, &opcode/1) == [
               Minga.Protocol.Opcodes.gui_window_overlay_delta()
             ]

      assert Enum.map(third.metal_commands, &opcode/1) == [WindowEncoder.opcode()]
      decoded = third.metal_commands |> hd() |> GUIWindowDecoder.decode()
      assert decoded.rows |> hd() |> Map.fetch!(:text) == "new"
    end
  end

  describe "encode_ui/2" do
    test "returns empty commands and unchanged caches for nil theme" do
      ui = %RenderModel.UI{theme: nil}
      caches = Caches.new()

      assert {[], ^caches} = GUI.encode_ui(ui, caches)
    end

    test "encodes theme when present" do
      model = %Theme{
        name: :test,
        color_slots: [{0x01, 0xFF0000}]
      }

      ui = %RenderModel.UI{theme: model}
      caches = Caches.new()

      assert {[cmd], updated_caches} = GUI.encode_ui(ui, caches)
      assert is_binary(cmd)
      assert <<0x74, _rest::binary>> = cmd
      assert updated_caches.last_theme_fp != nil
    end

    test "skips theme on second call with unchanged model" do
      model = %Theme{
        name: :test,
        color_slots: [{0x01, 0xFF0000}]
      }

      ui = %RenderModel.UI{theme: model}
      caches = Caches.new()

      {[_cmd], caches} = GUI.encode_ui(ui, caches)
      {cmds, _caches} = GUI.encode_ui(ui, caches)

      assert cmds == []
    end
  end

  defp opcode(<<opcode, _rest::binary>>), do: opcode
end
