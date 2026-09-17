defmodule Minga.Editing.Completion.ProviderBatch do
  @moduledoc "One identity-checked completion response batch from one provider."

  alias Minga.Editing.Completion.Item

  @enforce_keys [
    :session_id,
    :generation,
    :provider_id,
    :client,
    :request_ref,
    :items,
    :incomplete
  ]
  defstruct [:session_id, :generation, :provider_id, :client, :request_ref, :items, :incomplete]

  @type t :: %__MODULE__{
          session_id: reference(),
          generation: non_neg_integer(),
          provider_id: Item.provider_id(),
          client: pid(),
          request_ref: reference(),
          items: [Item.t()],
          incomplete: boolean()
        }

  @doc "Builds a provider batch from either LSP CompletionList or CompletionItem[] syntax."
  @spec from_response(
          reference(),
          non_neg_integer(),
          Item.provider_id(),
          pid(),
          reference(),
          map() | [map()] | nil
        ) :: t()
  def from_response(session_id, generation, provider_id, client, request_ref, response) do
    {raw_items, incomplete} = response_parts(response)

    %__MODULE__{
      session_id: session_id,
      generation: generation,
      provider_id: provider_id,
      client: client,
      request_ref: request_ref,
      items: Enum.map(raw_items, &Item.from_lsp(provider_id, &1)),
      incomplete: incomplete
    }
  end

  @spec response_parts(map() | [map()] | nil) :: {[map()], boolean()}
  defp response_parts(nil), do: {[], false}
  defp response_parts(items) when is_list(items), do: {items, false}

  defp response_parts(%{"items" => items} = response) when is_list(items),
    do: {items, Map.get(response, "isIncomplete", false) == true}

  defp response_parts(_response), do: {[], false}
end
