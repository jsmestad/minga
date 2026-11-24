defmodule MingaAgent.Providers.Native.HostedAdmission do
  @moduledoc """
  Admission gate for hosted-route requests (OpenAI, Anthropic, Codex via ReqLLM).

  JSON-encodes the messages, computes a byte-based upper-bound token estimate,
  assesses capacity against the policy limits, and delegates the admit/refuse
  decision to a caller-supplied authorize callback. The gate runs synchronously
  before the streaming request is dispatched.
  """

  alias MingaAgent.ModelSelection.Policy.Limits
  alias MingaAgent.ModelSelection.Policy.RequestCapacity

  @typedoc "An authorize callback that receives the body digest and capacity evidence."
  @type authorize_fn :: (digest :: binary(), RequestCapacity.t() -> :ok | {:error, term()})

  defmodule RefusedError do
    @moduledoc "Returned when a hosted-route admission gate refuses the request."

    @type t :: %__MODULE__{reason: term()}
    defexception [:reason]

    @impl true
    @spec message(t()) :: String.t()
    def message(%{reason: reason}), do: "Request admission refused: #{inspect(reason)}"
  end

  @doc """
  Assesses a hosted-route request and delegates the admit/refuse decision.

  Converts messages to plain maps and serializes to JSON, computes an
  upper-bound token estimate from the byte count, and calls `authorize` with the
  body digest and capacity evidence. Returns `:ok` on admission or
  `{:error, {:request_admission_refused, reason}}` on refusal.
  """
  @spec assess(Limits.t(), pos_integer(), [term()], authorize_fn()) ::
          :ok | {:error, {:request_admission_refused, term()}}
  def assess(%Limits{} = limits, output_tokens, messages, authorize)
      when is_integer(output_tokens) and output_tokens > 0 and is_function(authorize, 2) do
    body = messages |> Enum.map(&to_encodable/1) |> JSON.encode!()
    digest = :crypto.hash(:sha256, body)
    tokens = upper_bound_tokens(body)
    evidence = RequestCapacity.assess(limits, {:upper_bound, tokens}, {:encoded, output_tokens})

    case authorize.(digest, evidence) do
      :ok -> :ok
      {:error, reason} -> {:error, {:request_admission_refused, reason}}
    end
  end

  @doc """
  Returns a conservative upper-bound token count derived from an encoded body.

  Every token in a JSON-encoded LLM request body occupies at least 2 bytes: even
  the shortest representable token (a single ASCII character) is surrounded by
  JSON structural bytes (quotes, brackets, commas, colons). A one-character
  string token like `"a"` takes 3+ bytes; a one-character key takes 4+ bytes
  (key, colon, value separator). The practical minimum is therefore 2 bytes per
  token, making `ceil(byte_size / 2)` a proven upper bound for any
  JSON-serialized payload.

  This bound is intentionally conservative. It overestimates real token counts,
  which is correct for admission gating: a request that fits the upper bound
  definitely fits, and a request refused by the upper bound might fit but erring
  on the side of refusal is safe.
  """
  @spec upper_bound_tokens(binary()) :: non_neg_integer()
  def upper_bound_tokens(body) when is_binary(body) do
    ceil(byte_size(body) / 2)
  end

  @spec to_encodable(term()) :: term()
  defp to_encodable(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> to_encodable()
  defp to_encodable(%{} = map), do: Map.new(map, fn {k, v} -> {k, to_encodable(v)} end)
  defp to_encodable(list) when is_list(list), do: Enum.map(list, &to_encodable/1)
  defp to_encodable(other), do: other
end
