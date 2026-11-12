defmodule MingaAgent.Session.Request do
  @moduledoc """
  Immutable, versioned request snapshot handed from a Session to a provider worker.

  The snapshot carries the exact ReqLLM values for one request. Providers may
  consume it and return an outcome, but they do not own or mutate conversation
  history.
  """

  alias MingaAgent.Session.Prefix
  alias MingaAgent.Session.PrefixStore
  alias ReqLLM.Message

  @enforce_keys [:request_id, :turn_id, :conversation_revision, :messages]
  defstruct version: 1,
            request_id: nil,
            turn_id: nil,
            conversation_revision: 0,
            messages: [],
            epoch_id: :unknown,
            prefix: :unknown

  @type t :: %__MODULE__{
          version: pos_integer(),
          request_id: String.t(),
          turn_id: pos_integer(),
          conversation_revision: non_neg_integer(),
          messages: [Message.t()],
          epoch_id: PrefixStore.epoch_ref(),
          prefix: Prefix.t() | :unknown
        }

  @doc "Creates the immutable snapshot for one admitted request."
  @spec new(String.t(), pos_integer(), non_neg_integer(), [Message.t()]) :: t()
  @spec new(String.t(), pos_integer(), non_neg_integer(), [Message.t()], Prefix.t() | :unknown) ::
          t()
  def new(request_id, turn_id, conversation_revision, messages, prefix \\ :unknown)
      when is_binary(request_id) and is_integer(turn_id) and turn_id > 0 and
             is_integer(conversation_revision) and conversation_revision >= 0 and
             is_list(messages) do
    %__MODULE__{
      request_id: request_id,
      turn_id: turn_id,
      conversation_revision: conversation_revision,
      messages: messages,
      epoch_id: epoch_id(prefix),
      prefix: prefix
    }
  end

  @doc "Resolves a persisted request epoch without changing its message values."
  @spec resolve_prefix(t(), PrefixStore.t(), PrefixStore.epoch_ref()) :: t()
  def resolve_prefix(%__MODULE__{} = request, store, epoch_id) do
    %{request | epoch_id: epoch_id, prefix: PrefixStore.resolve(store, epoch_id)}
  end

  @spec epoch_id(Prefix.t() | :unknown) :: PrefixStore.epoch_ref()
  defp epoch_id(:unknown), do: :unknown
  defp epoch_id(%Prefix{epoch_id: id}), do: id
end
