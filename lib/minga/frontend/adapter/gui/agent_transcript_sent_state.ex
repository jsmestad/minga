defmodule Minga.Frontend.Adapter.GUI.AgentTranscriptSentState do
  @moduledoc """
  Per-frontend delta base for the resident agent transcript stream (0x86).

  Bundles the three values `Minga.Frontend.Adapter.GUI.AgentTranscriptEncoder`
  needs to compute the next delta: the change-detection fingerprint, the epoch it
  was captured under, and the ordered `{id, content_hash}` keys of the resident
  window it last emitted. Lives in `Minga.Frontend.Adapter.GUI.Caches`, never on
  the BEAM editor state.
  """

  @typedoc "An `{id, content_hash}` key for one resident message."
  @type key :: {non_neg_integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          fp: integer() | nil,
          epoch: non_neg_integer() | nil,
          keys: [key()],
          truncated?: boolean()
        }

  defstruct fp: nil, epoch: nil, keys: [], truncated?: false

  @spec emitted(integer(), non_neg_integer(), [key()], boolean()) :: t()
  def emitted(fp, epoch, keys, truncated?) do
    %__MODULE__{fp: fp, epoch: epoch, keys: keys, truncated?: truncated?}
  end
end
