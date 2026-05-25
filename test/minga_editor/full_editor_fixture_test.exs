defmodule MingaEditor.FullEditorFixtureTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Protocol

  test "full_editor fixture stays synced and renderable" do
    packets = fixture_packets()
    decoded_packets = Enum.map(packets, &Protocol.decode_command/1)

    assert File.exists?(fixture_path())
    assert first_opcode(packets) == Minga.Protocol.Opcodes.set_window_bg()
    assert Enum.all?(Enum.drop(decoded_packets, 1), &match?({:ok, _}, &1))
    assert Enum.any?(Enum.drop(decoded_packets, 1), &meaningful_draw_or_content_command?/1)
    assert List.last(decoded_packets) == {:ok, :batch_end}
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

  defp first_opcode([<<opcode::8, _rest::binary>> | _]), do: opcode

  defp meaningful_draw_or_content_command?({:ok, {:draw_text, _}}), do: true
  defp meaningful_draw_or_content_command?({:ok, {:draw_styled_text, _}}), do: true
  defp meaningful_draw_or_content_command?({:ok, {:gui_window_content, _}}), do: true
  defp meaningful_draw_or_content_command?({:ok, {:gui_status_bar, _}}), do: true
  defp meaningful_draw_or_content_command?(_), do: false
end
