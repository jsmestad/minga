defmodule Minga.Buffer.RendererConsume do
  @moduledoc """
  Atomic renderer ChangeLog observation.

  The buffer creates this value in the same GenServer call that advances the
  `:renderer` consumer. `snapshot` is an optional bounded line payload for the
  affected range; it never contains a document.

  `review_lease` binds a separate authorship query to the same buffer and text observation. Keep can change the lease without publishing a text delta.
  """

  alias Minga.Buffer.ChangeLog
  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.RenderSnapshot

  @typedoc "One buffer incarnation, text version, history revision and Git authorship revision."
  @type review_lease :: {pid(), non_neg_integer(), {pos_integer(), non_neg_integer()}}

  @typedoc "An inclusive range of source lines, independent of folding and wrapping."
  @type line_range :: {first :: non_neg_integer(), last :: non_neg_integer()}

  @typedoc "Additional source ranges changed since a known authorship lease."
  @type review_damage :: :reset_required | {:since, review_lease(), [line_range()]}

  @typedoc "Pending text, a pending deletion, or a non-actionable kept, human, or shared strand."
  @type review_region ::
          {:text, pos_integer(), Minga.Buffer.Position.t(), non_neg_integer()}
          | {:gap, pos_integer(), Minga.Buffer.Position.t()}
          | {:kept | :you | :shared, Minga.Buffer.Position.t(), non_neg_integer()}

  @enforce_keys [
    :version,
    :line_count,
    :change_sequence,
    :changes,
    :snapshot,
    :review_lease,
    :review_damage
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          version: non_neg_integer(),
          line_count: pos_integer(),
          change_sequence: ChangeLog.sequence(),
          changes: {:ok, [EditDelta.t()]} | :reset_required,
          snapshot: RenderSnapshot.t() | nil,
          review_lease: review_lease() | nil,
          review_damage: review_damage()
        }
end
