defmodule MingaEditor.FullEditorFixtureTest do
  use ExUnit.Case, async: true

  alias Minga.Protocol.Opcodes

  # The opcodes the curated `full_editor.bin` fixture is expected to contain.
  # Built from named constants so a wire-format rename surfaces here instead of
  # in opaque hex literals. Regenerate the fixture with
  # `mix run scripts/generate_snapshot_fixtures.exs` if this list changes.
  @expected_opcodes [
    Opcodes.set_window_bg(),
    Opcodes.gui_window_content(),
    Opcodes.gui_theme(),
    Opcodes.gui_status_bar(),
    Opcodes.gui_tab_bar(),
    Opcodes.gui_file_tree(),
    Opcodes.batch_end()
  ]

  test "full_editor fixture stays synced and renderable" do
    assert File.exists?(fixture_path())

    packets = fixture_packets()
    opcodes = Enum.map(packets, &opcode/1)

    # The replay order is curated: the frame opens with the window background
    # and closes with the batch flush.
    assert List.first(opcodes) == Opcodes.set_window_bg()
    assert List.last(opcodes) == Opcodes.batch_end()

    # A real full-editor frame carries the buffer window content plus the
    # surrounding chrome. The previous 46-byte stub failed exactly here.
    assert Opcodes.gui_window_content() in opcodes
    assert Opcodes.gui_file_tree() in opcodes
    assert Opcodes.gui_status_bar() in opcodes
    assert Opcodes.gui_tab_bar() in opcodes

    # Every packet must be non-empty and lead with a recognized opcode.
    allowed = MapSet.new(@expected_opcodes)

    for {packet, opcode} <- Enum.zip(packets, opcodes) do
      assert byte_size(packet) > 0
      assert MapSet.member?(allowed, opcode)
    end
  end

  defp fixture_packets do
    fixture_path() |> File.read!() |> split_packets()
  end

  defp fixture_path do
    Path.expand("../../zig/tests/fixtures/full_editor.bin", __DIR__)
  end

  defp split_packets(<<>>), do: []

  defp split_packets(<<size::32, packet::binary-size(size), rest::binary>>) do
    [packet | split_packets(rest)]
  end

  defp opcode(<<opcode::8, _rest::binary>>), do: opcode
end
