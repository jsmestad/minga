defmodule MingaEditor.FullEditorFixtureTest do
  use ExUnit.Case, async: true

  test "full_editor fixture stays synced and renderable" do
    packets = fixture_packets()
    opcodes = Enum.map(packets, &opcode/1)

    assert File.exists?(fixture_path())
    assert first_opcode(packets) == Minga.Protocol.Opcodes.set_window_bg()
    assert Enum.any?(opcodes, &meaningful_semantic_command?/1)
    assert List.last(opcodes) == Minga.Protocol.Opcodes.batch_end()
  end

  defp fixture_packets do
    File.read!(fixture_path()) |> split_packets()
  end

  defp fixture_path do
    Path.expand("../../zig/tests/fixtures/full_editor.bin", __DIR__)
  end

  defp split_packets(<<>>), do: []

  defp split_packets(<<size::32, packet::binary-size(size), rest::binary>>) do
    [packet | split_packets(rest)]
  end

  defp first_opcode([packet | _]), do: opcode(packet)

  defp opcode(<<opcode::8, _rest::binary>>), do: opcode

  defp meaningful_semantic_command?(opcode) when opcode in [0x80, 0x76], do: true
  defp meaningful_semantic_command?(_opcode), do: false
end
