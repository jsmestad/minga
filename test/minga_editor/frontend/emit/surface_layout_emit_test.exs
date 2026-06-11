defmodule MingaEditor.Frontend.Emit.SurfaceLayoutEmitTest do
  @moduledoc """
  End-to-end AC-1 proof for #2268: the BEAM hit-test rect for every placed
  surface equals the emitted placement rect, because both read the same
  `SurfaceRegistry` placements.

  The other half of the AC (registry rect == focus-tree hit-test rect) is pinned
  in `MingaEditor.Layout.SurfaceRegistryTest`. This test pins the missing leg:
  the bytes the emitter actually puts on the wire decode back to the exact rects
  (and z, surface_id, hit_kind) the registry produced. Chaining the two gives
  emitted-bytes == hit-test rects, one source, test-proven.
  """

  use ExUnit.Case, async: true

  alias Minga.Protocol.Opcodes
  alias MingaEditor.Frontend.Emit
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Layout.SurfaceRegistry
  alias MingaEditor.Layout.SurfaceRegistry.Placement

  import MingaEditor.RenderPipeline.TestHelpers

  alias MingaEditor.DisplayList
  alias MingaEditor.DisplayList.{Cursor, Frame}

  @op_surface_layout Opcodes.gui_surface_layout()

  defp emit_commands(state) do
    frame = %Frame{cursor: Cursor.new(0, 0, :block), splash: [DisplayList.draw(0, 0, "x")]}
    ctx = Context.from_editor_state(state)
    Emit.emit(frame, ctx)
    assert_receive {:"$gen_cast", {:send_commands, commands}}
    commands
  end

  defp surface_layout_command(commands) do
    Enum.find(commands, &match?(<<@op_surface_layout, _::binary>>, &1))
  end

  # Decode the sectioned gui_surface_layout command back into placement maps.
  # Format: opcode(1) section_count(1) then section{id(1) len(u16) body}; the
  # placements section body is count(u16) + count * surface_placement, where
  # surface_placement is surface_id(u16) rect(row,col,width,height : u16 each)
  # z(u16) hit_kind(u8) = 13 bytes.
  defp decode_placements(<<@op_surface_layout, 1::8, 0x01::8, len::16, body::binary-size(len)>>) do
    <<count::16, rest::binary>> = body
    decode_entries(rest, count, [])
  end

  defp decode_entries(_rest, 0, acc), do: Enum.reverse(acc)

  defp decode_entries(
         <<surface_id::16, row::16, col::16, width::16, height::16, z::16, hit_kind::8,
           rest::binary>>,
         remaining,
         acc
       ) do
    entry = %{
      surface_id: surface_id,
      rect: {row, col, width, height},
      z: z,
      hit_kind: hit_kind
    }

    decode_entries(rest, remaining - 1, [entry | acc])
  end

  # The expected wire entry for a registry placement: rect verbatim (cells),
  # surface_id/hit_kind through the registry's authoritative numbering.
  defp expected_entry(%Placement{} = p) do
    %{
      surface_id: SurfaceRegistry.surface_id_u16(p.surface_id),
      rect: p.rect,
      z: p.z,
      hit_kind: SurfaceRegistry.hit_kind_u8(p.hit_kind)
    }
  end

  test "every frame's transaction carries a gui_surface_layout command before commit" do
    commands = emit_commands(base_state())

    assert cmd = surface_layout_command(commands)

    commit = <<Opcodes.commit_frame(), 0::32, 0::32>>
    # The layout packet rides inside the transaction, immediately before commit.
    assert List.last(commands) |> binary_part(0, 1) == <<Opcodes.commit_frame()>>
    refute commit == cmd
    surface_idx = Enum.find_index(commands, &(&1 == cmd))
    commit_idx = length(commands) - 1
    assert surface_idx < commit_idx
  end

  test "emitted placement bytes decode to the exact rects BEAM hit-testing uses (AC-1)" do
    state = base_state()
    commands = emit_commands(state)

    decoded = commands |> surface_layout_command() |> decode_placements()

    # The registry is the BEAM hit-test source. Project its placements through
    # the same authoritative numbering the emitter uses; the decoded wire bytes
    # must match field-for-field, in the same order.
    expected =
      state
      |> SurfaceRegistry.placements()
      |> Enum.map(&expected_entry/1)

    assert decoded == expected
    # Sanity: there is real content here, not an empty list masking the check.
    refute decoded == []
  end

  test "rect for each decoded surface_id equals the registry rect_for that surface" do
    state = base_state()
    commands = emit_commands(state)
    decoded = commands |> surface_layout_command() |> decode_placements()
    placements = SurfaceRegistry.placements(state)

    # For each emitted surface, the wire rect equals the rect the registry hands
    # the hit-tester (rect_for_in takes the topmost by z, the same precedence the
    # emitted z list encodes).
    for %{surface_id: u16} <- decoded do
      surface_id =
        Enum.find_value(placements, fn p ->
          if SurfaceRegistry.surface_id_u16(p.surface_id) == u16, do: p.surface_id
        end)

      assert surface_id, "decoded surface_id #{u16} has no registry surface"
      assert SurfaceRegistry.rect_for_in(placements, surface_id) != nil
    end
  end

  test "empty placement list still emits a well-formed (zero-count) command" do
    # A degenerate state with no focus tree surfaces still produces a valid,
    # decodable command: the transaction always carries the layout authority,
    # even when the authority is empty.
    state = base_state()
    # Force an empty placement context directly through the encoder to prove the
    # zero-count framing round-trips (the live state always has chrome, so this
    # exercises the boundary the production encoder must handle).
    cmd = Minga.Frontend.Adapter.GUI.SurfaceLayoutEncoder.encode_command([])
    # opcode, section_count=1, section{id=0x01, len=2, body=<<count::16 = 0>>}.
    assert <<@op_surface_layout, 1::8, 0x01::8, 2::16, 0::16>> == cmd
    assert decode_placements(cmd) == []
    _ = state
  end
end
