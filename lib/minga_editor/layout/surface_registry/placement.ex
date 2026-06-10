defmodule MingaEditor.Layout.SurfaceRegistry.Placement do
  @moduledoc """
  One placed surface: its identity, rect, z band, and hit kind.

  This struct mirrors the `surface_placement{surface_id, rect, z, hit_kind}`
  shape the consult locked for the `gui_surface_layout` wire opcode (#2268),
  expressed BEAM-side as data. It carries no wire encoding itself; the encoder
  (a later #2268 child) reads `surface_id`/`rect`/`z`/`hit_kind` and maps
  `surface_id` to `u16` via
  `MingaEditor.Layout.SurfaceRegistry.surface_id_u16/1`.

  `MingaEditor.Layout.SurfaceRegistry` is the only module that constructs these
  (one writer per struct).
  """

  alias MingaEditor.Layout.SurfaceRegistry

  @typedoc "A placed surface entry."
  @type t :: %__MODULE__{
          surface_id: SurfaceRegistry.surface_id(),
          rect: MingaEditor.Layout.rect(),
          z: non_neg_integer(),
          hit_kind: SurfaceRegistry.hit_kind()
        }

  @enforce_keys [:surface_id, :rect, :z, :hit_kind]
  defstruct [:surface_id, :rect, :z, :hit_kind]

  @doc "Constructs a placement. Called only by `SurfaceRegistry`."
  @spec new(
          SurfaceRegistry.surface_id(),
          MingaEditor.Layout.rect(),
          non_neg_integer(),
          SurfaceRegistry.hit_kind()
        ) :: t()
  def new(surface_id, rect, z, hit_kind) do
    %__MODULE__{surface_id: surface_id, rect: rect, z: z, hit_kind: hit_kind}
  end
end
