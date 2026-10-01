defmodule MingaAgent.ArtifactQuota.Usage do
  @moduledoc "Aggregate logical artifact quota usage without content or session identifiers."

  @type t :: %__MODULE__{
          bytes: non_neg_integer(),
          items: non_neg_integer(),
          artifacts: non_neg_integer(),
          open_captures: non_neg_integer(),
          namespaces: non_neg_integer(),
          limit_bytes: pos_integer()
        }

  @enforce_keys [:bytes, :items, :artifacts, :open_captures, :namespaces, :limit_bytes]
  defstruct @enforce_keys

  @doc false
  @spec new(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer()
        ) :: t()
  def new(bytes, items, artifacts, open_captures, namespaces, limit_bytes),
    do: %__MODULE__{
      bytes: bytes,
      items: items,
      artifacts: artifacts,
      open_captures: open_captures,
      namespaces: namespaces,
      limit_bytes: limit_bytes
    }
end
