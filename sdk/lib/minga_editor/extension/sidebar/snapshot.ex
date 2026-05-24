defmodule MingaEditor.Extension.Sidebar.Snapshot do
  @moduledoc """
  Compile-time SDK struct for cached sidebar snapshots.

  Runtime Minga uses the matching module to derive structural and selection fingerprints. Extension code can construct this struct when publishing sidebar content.
  """

  @type row :: map()
  @type status :: :ready | :loading | :error | :empty
  @type t :: %__MODULE__{
          rows: [row()],
          status: status(),
          message: String.t() | nil,
          structural_fingerprint: non_neg_integer(),
          selection_fingerprint: non_neg_integer(),
          selected_id: String.t() | nil,
          active_id: String.t() | nil
        }

  defstruct rows: [],
            status: :ready,
            message: nil,
            structural_fingerprint: 0,
            selection_fingerprint: 0,
            selected_id: nil,
            active_id: nil
end
