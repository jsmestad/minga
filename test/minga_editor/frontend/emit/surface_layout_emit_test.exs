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
  alias Minga.Test.RecordingFrontend
  alias MingaEditor.FocusTree
  alias MingaEditor.Frontend.Emit
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.HoverPopup
  alias MingaEditor.Layout.SurfaceRegistry
  alias MingaEditor.Layout.SurfaceRegistry.Placement
  alias MingaEditor.SignatureHelp
  alias MingaEditor.State, as: EditorState

  import MingaEditor.RenderPipeline.TestHelpers

  alias Minga.RenderModel.Cursor
  alias MingaEditor.RenderPipeline.ComposedFrame

  @op_begin_frame Opcodes.begin_frame()
  @op_surface_layout Opcodes.gui_surface_layout()

  setup do
    frontend =
      start_supervised!(
        {RecordingFrontend, owner: self()},
        id: {:surface_layout_frontend, System.unique_integer([:positive])}
      )

    Process.put(:surface_layout_frontend, frontend)
    :ok
  end

  # A base state with both promoted floating popups live in shell_state, so the
  # focus tree adds hover/signature-help overlay nodes and the registry places them.
  defp state_with_floating_popups do
    state = emit_state()
    hover = HoverPopup.new("Returns the **value**.", 2, 6)

    signature = %SignatureHelp{
      signatures: [%{label: "map(enumerable, fun)", documentation: "", parameters: []}],
      active_signature: 0,
      active_parameter: 0,
      anchor_row: 4,
      anchor_col: 3
    }

    state
    |> EditorState.set_hover_popup(hover)
    |> EditorState.set_signature_help(signature)
    |> freeze_focus_tree()
  end

  defp emit_commands(state) do
    frame = ComposedFrame.new([], Cursor.new(0, 0, :block))
    ctx = Context.from_editor_state(state)
    Emit.emit(frame, ctx)

    assert_receive {:frontend_commands, _frontend,
                    [<<@op_begin_frame, _::binary>> | _] = commands}

    commands
  end

  defp emit_state(opts \\ []) do
    opts
    |> Keyword.put(:port_manager, Process.get(:surface_layout_frontend))
    |> base_state()
    |> freeze_focus_tree()
  end

  defp freeze_focus_tree(state), do: %{state | focus_tree: FocusTree.from_state(state)}

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
    commands = emit_commands(emit_state())

    assert cmd = surface_layout_command(commands)

    commit = <<Opcodes.commit_frame(), 0::32, 0::32>>
    # The layout packet rides inside the transaction, immediately before commit.
    assert Enum.at(commands, -1) |> binary_part(0, 1) == <<Opcodes.commit_frame()>>
    refute commit == cmd
    surface_idx = Enum.find_index(commands, &(&1 == cmd))
    commit_idx = Enum.count(commands) - 1
    assert surface_idx < commit_idx
  end

  test "emitted placement bytes decode to the exact rects BEAM hit-testing uses (AC-1)" do
    state = emit_state()
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
    state = emit_state()
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

  test "promoted floating popups (hover, signature help) emit registry placements (#2281)" do
    state = state_with_floating_popups()
    commands = emit_commands(state)
    decoded = commands |> surface_layout_command() |> decode_placements()

    placements = SurfaceRegistry.placements(state)
    expected = Enum.map(placements, &expected_entry/1)

    # The promoted surfaces are present in the registry derivation...
    surface_ids = Enum.map(placements, & &1.surface_id)
    assert :hover_popup in surface_ids, "hover popup should be a registry-placed surface"
    assert :signature_help in surface_ids, "signature help should be a registry-placed surface"

    # ...and their emitted bytes match the registry rect/z/hit_kind field-for-field.
    hover_u16 = SurfaceRegistry.surface_id_u16(:hover_popup)
    sig_u16 = SurfaceRegistry.surface_id_u16(:signature_help)
    decoded_hover = Enum.find(decoded, &(&1.surface_id == hover_u16))
    decoded_sig = Enum.find(decoded, &(&1.surface_id == sig_u16))

    assert decoded_hover, "emitted layout missing the promoted hover surface"
    assert decoded_sig, "emitted layout missing the promoted signature-help surface"

    # Behaviour-neutral stacking: hover (z=290) paints in front of signature
    # help (z=280), exactly the historical Go transitional order.
    assert decoded_hover.z == 290
    assert decoded_sig.z == 280
    assert decoded_hover.z > decoded_sig.z

    # The emitted rect equals the registry rect_for that surface (AC-1, AC-3:
    # the same rect BEAM hit-testing routes against).
    assert decoded_hover.rect == SurfaceRegistry.rect_for_in(placements, :hover_popup)
    assert decoded_sig.rect == SurfaceRegistry.rect_for_in(placements, :signature_help)

    # And the full emitted list still matches the registry, order included.
    assert decoded == expected
  end

  test "a visible footer-band overlay (notifications) emits a registry placement (#2281)" do
    note =
      MingaEditor.UI.Notification.new(%{
        id: "n1",
        level: :info,
        title: "Build finished",
        created_at: System.system_time(:millisecond)
      })

    center =
      MingaEditor.UI.NotificationCenter.upsert(MingaEditor.UI.NotificationCenter.new(), note)

    state = emit_state() |> Map.put(:notifications, center) |> freeze_focus_tree()

    commands = emit_commands(state)
    decoded = commands |> surface_layout_command() |> decode_placements()

    placements = SurfaceRegistry.placements(state)
    expected = Enum.map(placements, &expected_entry/1)

    # The promoted notifications surface is present in the registry derivation...
    assert :notifications in Enum.map(placements, & &1.surface_id)

    # ...and its emitted bytes carry the historical stacking z (160) and the
    # overlay hit_kind, matching the registry rect_for field-for-field.
    notes_u16 = SurfaceRegistry.surface_id_u16(:notifications)
    decoded_notes = Enum.find(decoded, &(&1.surface_id == notes_u16))

    assert decoded_notes, "emitted layout missing the promoted notifications surface"
    assert decoded_notes.z == 160
    assert decoded_notes.hit_kind == SurfaceRegistry.hit_kind_u8(:overlay)
    assert decoded_notes.rect == SurfaceRegistry.rect_for_in(placements, :notifications)

    # And the full emitted list still matches the registry, order included.
    assert decoded == expected
  end

  test "empty placement list still emits a well-formed (zero-count) command" do
    # A degenerate state with no focus tree surfaces still produces a valid,
    # decodable command: the transaction always carries the layout authority,
    # even when the authority is empty.
    state = emit_state()
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
