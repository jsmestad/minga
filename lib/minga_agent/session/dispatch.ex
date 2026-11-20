defmodule MingaAgent.Session.Dispatch do
  @moduledoc "A single attempt to dispatch a round from a Session-owned continuation."

  alias MingaAgent.ModelSelection.Policy.RequestCapacity
  alias MingaAgent.Session.{Prefix, PrefixStore, Request}

  @type source :: :initial | {:checkpoint, String.t()}
  @type status ::
          :assessing
          | {:admitted, binary(), RequestCapacity.t()}
          | {:refused, RequestCapacity.t()}
  @type t :: %__MODULE__{
          id: reference(),
          request_id: String.t(),
          revision: non_neg_integer(),
          epoch_id: PrefixStore.epoch_ref(),
          selection_id: String.t(),
          source: source(),
          status: status()
        }

  @enforce_keys [:id, :request_id, :revision, :epoch_id, :selection_id, :source, :status]
  defstruct @enforce_keys

  @doc "Starts assessing a fresh attempt against an existing request and exact source."
  @spec begin(Request.t(), source()) :: t()
  def begin(
        %Request{prefix: %Prefix{identity: %{selection_id: selection_id}}} = request,
        source
      )
      when is_binary(selection_id) do
    %__MODULE__{
      id: make_ref(),
      request_id: request.request_id,
      revision: request.conversation_revision,
      epoch_id: request.epoch_id,
      selection_id: selection_id,
      source: source,
      status: :assessing
    }
  end

  @doc "Consumes the matching assessment attempt once and binds the admitted prepared body."
  @spec assess(t(), t(), binary(), RequestCapacity.t()) ::
          {:ok, t()} | {:error, :stale_dispatch}
  def assess(
        %__MODULE__{status: :assessing} = current,
        current,
        digest,
        %RequestCapacity{} = evidence
      )
      when is_binary(digest) and byte_size(digest) == 32 do
    status =
      case evidence.decision do
        :ok -> {:admitted, digest, evidence}
        {:error, _reason} -> {:refused, evidence}
      end

    {:ok, %{current | status: status}}
  end

  def assess(%__MODULE__{}, %__MODULE__{}, _digest, _assessment), do: {:error, :stale_dispatch}
end
