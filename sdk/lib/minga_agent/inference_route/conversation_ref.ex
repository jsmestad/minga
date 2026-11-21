defmodule MingaAgent.InferenceRoute.ConversationRef do
  @moduledoc """
  Minga-owned identity of the conversation one route request belongs to, passed as `opts[:minga_conversation]`.

  Treat `:summary` and `:title` requests as isolated queries: offer no tools and do not continue a session from them.

  This is a compile-time stub.
  """

  @enforce_keys [:session_id, :owner, :epoch_id, :conversation_revision, :request_id, :purpose]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          owner: pid(),
          epoch_id: String.t() | nil,
          conversation_revision: non_neg_integer() | nil,
          request_id: term(),
          purpose: :turn | :summary | :title
        }
end
