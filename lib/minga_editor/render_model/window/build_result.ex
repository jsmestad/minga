defmodule MingaEditor.RenderModel.Window.BuildResult do
  @moduledoc "Typed statistics returned with a semantic window build."

  alias Minga.RenderModel.Window.{Row, RowSlotAllocator}
  alias MingaEditor.RenderModel.Window.{ResidentBuild, VisualRow}

  @enforce_keys ~w(rasterized retained_rows retained_wrap_lines resident_build resident_rows_spliced row_slot_allocator)a
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          rasterized: non_neg_integer(),
          retained_rows: %{optional(Row.row_id()) => {non_neg_integer(), Row.t()}},
          retained_wrap_lines: %{optional(Row.row_id()) => {non_neg_integer(), [VisualRow.t()]}},
          resident_build: ResidentBuild.t() | nil,
          resident_rows_spliced: non_neg_integer(),
          row_slot_allocator: RowSlotAllocator.t()
        }
end
