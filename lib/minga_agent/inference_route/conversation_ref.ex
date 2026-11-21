defmodule MingaAgent.InferenceRoute.ConversationRef do
  @moduledoc """
  Core-owned identity of the conversation one route request belongs to.

  A `:turn` request belongs to a session conversation. Its `epoch_id` changes on branch, reset, or compaction, and its `conversation_revision` changes whenever the committed history changes. Tool follow-ups inside one turn keep the same `request_id`, `epoch_id`, and revision; the route tells them apart by the messages it receives. Core never infers identity from history digests.

  A `:summary` or `:title` request is an isolated query, not a conversation step. Its `epoch_id` and `conversation_revision` may be nil, and its `request_id` is fresh. Routes must treat these requests as isolated: offer no tools and do not continue or record a session from them.
  """

  @enforce_keys [
    :session_id,
    :owner,
    :epoch_id,
    :conversation_revision,
    :request_id,
    :purpose
  ]
  defstruct @enforce_keys

  @type purpose :: :turn | :summary | :title

  @typedoc "Identity of one step in a session conversation."
  @type turn :: %__MODULE__{
          session_id: String.t() | nil,
          owner: pid(),
          epoch_id: String.t(),
          conversation_revision: non_neg_integer(),
          request_id: term(),
          purpose: :turn
        }

  @typedoc "Identity of an isolated query such as a compaction summary."
  @type isolated :: %__MODULE__{
          session_id: String.t() | nil,
          owner: pid(),
          epoch_id: String.t() | nil,
          conversation_revision: non_neg_integer() | nil,
          request_id: term(),
          purpose: :summary | :title
        }

  @type t :: turn() | isolated()

  @type error :: {:invalid_conversation_ref, atom()}

  defguardp optional_session(id) when is_nil(id) or (is_binary(id) and id != "")
  defguardp optional_epoch(id) when is_nil(id) or (is_binary(id) and id != "")
  defguardp optional_revision(rev) when is_nil(rev) or (is_integer(rev) and rev >= 0)

  @doc "Builds a conversation identity. A `:turn` requires a string epoch and an integer revision."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, error()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(
        %{
          session_id: session_id,
          owner: owner,
          epoch_id: epoch_id,
          conversation_revision: revision,
          request_id: request_id,
          purpose: :turn
        } = attrs
      )
      when optional_session(session_id) and is_pid(owner) and is_binary(epoch_id) and
             epoch_id != "" and is_integer(revision) and revision >= 0 and
             not is_nil(request_id) do
    {:ok, struct!(__MODULE__, Map.take(attrs, @enforce_keys))}
  end

  def new(
        %{
          session_id: session_id,
          owner: owner,
          epoch_id: epoch_id,
          conversation_revision: revision,
          request_id: request_id,
          purpose: purpose
        } = attrs
      )
      when purpose in [:summary, :title] and optional_session(session_id) and is_pid(owner) and
             optional_epoch(epoch_id) and optional_revision(revision) and not is_nil(request_id) do
    {:ok, struct!(__MODULE__, Map.take(attrs, @enforce_keys))}
  end

  def new(%{purpose: purpose}) when purpose in [:turn, :summary, :title],
    do: {:error, {:invalid_conversation_ref, purpose}}

  def new(_attrs), do: {:error, {:invalid_conversation_ref, :purpose}}
end
