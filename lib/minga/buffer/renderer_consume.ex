defmodule Minga.Buffer.RendererConsume do
  @moduledoc """
  Atomic renderer ChangeLog observation.

  The buffer creates this value in the same GenServer call that advances the
  `:renderer` consumer. `snapshot` is an optional bounded line payload for the
  affected range; it never contains a document.
  """

  alias Minga.Buffer.ChangeLog
  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.RenderSnapshot

  @enforce_keys [:version, :line_count, :change_sequence, :changes, :snapshot]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          version: non_neg_integer(),
          line_count: pos_integer(),
          change_sequence: ChangeLog.sequence(),
          changes: {:ok, [EditDelta.t()]} | :reset_required,
          snapshot: RenderSnapshot.t() | nil
        }
end
