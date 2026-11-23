defmodule MingaAgent.Providers.Native.UsageLimitSignal do
  @moduledoc """
  Finds a subscription usage limit inside a native provider failure.

  A failed stream reaches the agent loop wrapped in ReqLLM errors, and a failed dispatch in Minga's own tuples. This module unwraps both, so ReqLLM error shapes stay in the provider layer and `MingaAgent.UsageLimit` reads only the HTTP status, provider code, and body. See `MingaAgent.UsageLimit` for what each provider sends.
  """

  alias MingaAgent.UsageLimit

  @wrappers [:http_streaming_failed, :exit, :throw, :error]

  @doc """
  Returns the usage limit a failure reports, or `:none` for every other failure, including a transient 429.

  `service` names the subscription in the message, and `observed_at` anchors a reset reported only as `resets_in_seconds`. A text-only failure that names `usage_limit_reached` is a usage limit with no known plan, window, or reset.
  """
  @spec detect(term(), String.t(), DateTime.t()) :: {:ok, UsageLimit.t()} | :none
  def detect(%ReqLLM.Error.API.Stream{cause: nil, reason: reason}, service, observed_at),
    do: detect(reason, service, observed_at)

  def detect(%ReqLLM.Error.API.Stream{cause: cause}, service, observed_at),
    do: detect(cause, service, observed_at)

  def detect({wrapper, reason}, service, observed_at) when wrapper in @wrappers,
    do: detect(reason, service, observed_at)

  def detect(%{status: status} = reason, service, observed_at) do
    UsageLimit.from_response(
      service,
      status,
      Map.get(reason, :provider_code),
      Map.get(reason, :response_body),
      observed_at
    )
  end

  def detect(%{"status" => status} = reason, service, observed_at) do
    UsageLimit.from_response(
      service,
      status,
      Map.get(reason, "provider_code"),
      Map.get(reason, "response_body"),
      observed_at
    )
  end

  def detect(message, service, _observed_at) when is_binary(message) do
    if UsageLimit.message_signal?(message), do: {:ok, UsageLimit.unknown(service)}, else: :none
  end

  def detect(_reason, _service, _observed_at), do: :none
end
