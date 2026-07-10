defmodule Minga.Frontend.Adapter.GUI.SurfaceLayoutEncoder do
  @moduledoc """
  Encodes `gui_surface_layout` (0xA4): the authoritative per-frame surface
  placement carrier (#2219 child E / #2268).

  This is the single emitter of `gui_surface_layout`. It takes wire-shaped
  placement maps (already numbered by `MingaEditor.Layout.SurfaceRegistry`, the
  one source of surface rects and z-order that also feeds BEAM mouse
  hit-testing) and lays them out as a sectioned command using the
  schema-generated pure encoder
  `Minga.Protocol.Encode.encode_gui_surface_layout_placements/1`. Because both
  the placement bytes and the BEAM hit-test read the same registry placements,
  the emitted rect for every surface equals its hit-test rect by construction
  (#2268 AC-1).

  ## Identity unification (#2268)

  The schema carries `surface_id` as a raw `u16` and `hit_kind` as a raw `u8`
  with no enum (a new schema vocabulary was explicitly avoided). The numeric
  identity is authoritative in `SurfaceRegistry`, which projects each placement
  to its wire shape (`SurfaceRegistry.wire_placements/1`). This encoder consumes
  those plain maps and never depends on `MingaEditor.*`: one writer (the
  registry owns the numbering), one reader (this encoder lays out bytes).

  ## Framing

  Sectioned framing (`opcode + section_count + section{id, len16, body}`) reuses
  the gui_window_content/picker counted-array carrier so the generator emits a
  placement decoder both frontends already know how to size (the reviewer-
  adjudicated carrier choice from child A). There is a single section,
  `placements` (id 0x01), holding a counted array of `surface_placement`.
  """

  alias Minga.Frontend.Adapter.GUI.Wire
  alias Minga.Protocol.Encode
  alias Minga.Protocol.Opcodes

  @op_gui_surface_layout Opcodes.gui_surface_layout()
  @section_placements 0x01

  @typedoc "A placement already projected to its wire shape (see SurfaceRegistry.wire_placement/0)."
  @type wire_placement :: %{
          surface_id: non_neg_integer(),
          rect: %{
            row: non_neg_integer(),
            col: non_neg_integer(),
            width: non_neg_integer(),
            height: non_neg_integer()
          },
          z: non_neg_integer(),
          hit_kind: non_neg_integer()
        }

  @doc """
  Encodes the frame's wire-shaped surface placements into a `gui_surface_layout`
  command.

  Always emits (one section, possibly with an empty placement array). The
  command is part of the frame transaction, so it ships every frame between
  begin_frame and commit_frame; there is no skip-if-unchanged cache because the
  placement list IS the per-frame layout authority. Invalid bounded fields are
  rejected before encoding so a frame can never contain truncated placement data.
  """
  @spec encode_command([wire_placement()]) :: binary()
  def encode_command(placements) when is_list(placements) do
    validated = Enum.map(placements, &validate/1)

    section =
      Wire.encode_section(
        @section_placements,
        Encode.encode_gui_surface_layout_placements(validated)
      )

    IO.iodata_to_binary([<<@op_gui_surface_layout, 1::8>>, section])
  end

  @spec validate(wire_placement()) :: map()
  defp validate(%{surface_id: surface_id, rect: rect, z: z, hit_kind: hit_kind} = placement) do
    validate_uint!(:surface_id, surface_id, Wire.max_u16())
    validate_uint!(:row, rect.row, Wire.max_u16())
    validate_uint!(:col, rect.col, Wire.max_u16())
    validate_uint!(:width, rect.width, Wire.max_u16())
    validate_uint!(:height, rect.height, Wire.max_u16())
    validate_uint!(:z, z, Wire.max_u16())
    validate_uint!(:hit_kind, hit_kind, Wire.max_u8())
    placement
  end

  @spec validate_uint!(atom(), term(), non_neg_integer()) :: :ok
  defp validate_uint!(field, value, max),
    do: Wire.validate_uint!(:gui_surface_layout, field, value, max)
end
