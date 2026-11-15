defmodule MingaEditor.Agent.DiffReview.DisplayLine do
  @moduledoc """
  One unified-diff line with its authoritative source coordinate.

  Baseline coordinates survive edits to the agent's post-image. Added lines and hunk headers reference a hunk in their owning review; producers match that hunk across revisions before allocating durable render identities. These coordinates are not display indexes or wire row IDs.
  """

  @type kind :: :context | :added | :removed | :hunk_header
  @type source ::
          {:baseline, non_neg_integer()}
          | {:hunk_header, non_neg_integer()}
          | {:added, non_neg_integer(), non_neg_integer()}

  @enforce_keys [:source, :text, :kind]
  defstruct [:source, :text, :kind, hunk_index: nil]

  @type t :: %__MODULE__{
          source: source(),
          text: String.t(),
          kind: kind(),
          hunk_index: non_neg_integer() | nil
        }

  @doc "Builds a display line without allocating a frontend render identity."
  @spec new(source(), String.t(), kind(), non_neg_integer() | nil) :: t()
  def new(source, text, kind, hunk_index \\ nil) do
    %__MODULE__{source: source, text: text, kind: kind, hunk_index: hunk_index}
  end
end
