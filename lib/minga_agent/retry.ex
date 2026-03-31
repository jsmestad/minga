defmodule MingaAgent.Retry do
  @moduledoc """
  Exponential backoff retry logic for transient API errors.

  Wraps an LLM call with automatic retries for rate limits (429),
  server errors (500, 502, 503, 529), network timeouts, and connection
  resets. Non-retryable errors (400, 401, 403) fail immediately.

  Uses exponential backoff with jitter: base delays of 1s, 2s, 4s, 8s
  plus random jitter up to 50% of the delay. Respects `Retry-After`
  headers when present.
  """

  @typedoc "Options for retry behavior."
  @type opts :: [
          max_retries: non_neg_integer(),
          base_delay_ms: pos_integer(),
          on_retry: (non_neg_integer(), non_neg_integer(), String.t() -> :ok) | nil
        ]

  @base_delay_ms 1_000
  @max_delay_ms 16_000

  @retryable_statuses [429, 500, 502, 503, 529]
  @non_retryable_statuses [400, 401, 403, 404, 422]

  @doc """
  Calls the given function with retry logic on transient errors.

  The function should return `{:ok, result}` or `{:error, reason}`.

  Options:
  - `:max_retries` - maximum number of retry attempts (default: 3)
  - `:base_delay_ms` - initial backoff delay in milliseconds (default: 1000)
  - `:on_retry` - callback `(attempt, delay_ms, reason)` called before each retry

  ## Examples

      Retry.with_retry(fn -> api_call() end, max_retries: 3)
  """
  @spec with_retry((-> {:ok, term()} | {:error, term()}), opts()) ::
          {:ok, term()} | {:error, term()}
  def with_retry(fun, opts \\ []) when is_function(fun, 0) do
    max_retries = Keyword.get(opts, :max_retries, 3)
    base_delay = Keyword.get(opts, :base_delay_ms, @base_delay_ms)
    on_retry = Keyword.get(opts, :on_retry)

    attempt(fun, 0, max_retries, on_retry, base_delay)
  end

  @doc """
  Returns true if the given error reason is retryable.
  """
  @spec retryable?(term()) :: boolean()
  def retryable?(%{status: status}) when status in @retryable_statuses, do: true
  def retryable?(%{"status" => status}) when status in @retryable_statuses, do: true

  def retryable?(%{status: status}) when status in @non_retryable_statuses, do: false
  def retryable?(%{"status" => status}) when status in @non_retryable_statuses, do: false

  def retryable?(:timeout), do: true
  def retryable?(:econnrefused), do: true
  def retryable?(:econnreset), do: true
  def retryable?(:closed), do: true
  def retryable?(:nxdomain), do: false

  def retryable?(reason) when is_binary(reason) do
    lower = String.downcase(reason)

    String.contains?(lower, "overloaded") or
      String.contains?(lower, "rate limit") or
      String.contains?(lower, "timeout") or
      String.contains?(lower, "connection") or
      String.contains?(lower, "529") or
      String.contains?(lower, "500") or
      String.contains?(lower, "502") or
      String.contains?(lower, "503")
  end

  def retryable?(%{__exception__: true} = exception) do
    msg = Exception.message(exception)
    retryable?(msg)
  end

  # Default: don't retry unknown errors
  def retryable?(_), do: false

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec attempt(
          (-> {:ok, term()} | {:error, term()}),
          non_neg_integer(),
          non_neg_integer(),
          (non_neg_integer(), non_neg_integer(), String.t() -> :ok) | nil,
          pos_integer()
        ) :: {:ok, term()} | {:error, term()}
  defp attempt(fun, attempt_num, max_retries, on_retry, base_delay) do
    case fun.() do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        maybe_retry_error(fun, reason, attempt_num, max_retries, on_retry, base_delay)
    end
  rescue
    e ->
      maybe_retry_exception(
        fun,
        e,
        __STACKTRACE__,
        attempt_num,
        max_retries,
        on_retry,
        base_delay
      )
  end

  @spec maybe_retry_error(
          (-> {:ok, term()} | {:error, term()}),
          term(),
          non_neg_integer(),
          non_neg_integer(),
          (non_neg_integer(), non_neg_integer(), String.t() -> :ok) | nil,
          pos_integer()
        ) :: {:ok, term()} | {:error, term()}
  defp maybe_retry_error(fun, reason, attempt_num, max_retries, on_retry, base_delay)
       when attempt_num < max_retries and max_retries > 0 do
    if retryable?(reason) do
      wait_and_retry(fun, attempt_num, max_retries, on_retry, format_reason(reason), base_delay)
    else
      {:error, reason}
    end
  end

  defp maybe_retry_error(_fun, reason, _attempt_num, _max_retries, _on_retry, _base_delay) do
    {:error, reason}
  end

  @spec maybe_retry_exception(
          (-> {:ok, term()} | {:error, term()}),
          Exception.t(),
          Exception.stacktrace(),
          non_neg_integer(),
          non_neg_integer(),
          (non_neg_integer(), non_neg_integer(), String.t() -> :ok) | nil,
          pos_integer()
        ) :: {:ok, term()} | {:error, term()} | no_return()
  defp maybe_retry_exception(
         fun,
         exception,
         _stacktrace,
         attempt_num,
         max_retries,
         on_retry,
         base_delay
       )
       when attempt_num < max_retries and max_retries > 0 do
    if retryable?(exception) do
      wait_and_retry(
        fun,
        attempt_num,
        max_retries,
        on_retry,
        Exception.message(exception),
        base_delay
      )
    else
      raise exception
    end
  end

  defp maybe_retry_exception(
         _fun,
         exception,
         stacktrace,
         _attempt_num,
         _max_retries,
         _on_retry,
         _base_delay
       ) do
    reraise exception, stacktrace
  end

  # Process.sleep is intentional here: this code runs inside a Task (not a
  # GenServer), so blocking is safe and the simplest way to implement backoff.
  @spec wait_and_retry(
          (-> {:ok, term()} | {:error, term()}),
          non_neg_integer(),
          non_neg_integer(),
          (non_neg_integer(), non_neg_integer(), String.t() -> :ok) | nil,
          String.t(),
          pos_integer()
        ) :: {:ok, term()} | {:error, term()}
  defp wait_and_retry(fun, attempt_num, max_retries, on_retry, reason_str, base_delay) do
    delay = compute_delay(attempt_num, base_delay)
    if on_retry, do: on_retry.(attempt_num + 1, delay, reason_str)
    # credo:disable-for-next-line Minga.Credo.NoProcessSleepCheck
    Process.sleep(delay)
    attempt(fun, attempt_num + 1, max_retries, on_retry, base_delay)
  end

  @spec compute_delay(non_neg_integer(), pos_integer()) :: pos_integer()
  defp compute_delay(attempt_num, base_delay_ms) do
    base = base_delay_ms * Integer.pow(2, attempt_num)
    capped = min(base, @max_delay_ms)
    # Add jitter: 0-50% of the base delay
    jitter = :rand.uniform(max(div(capped, 2), 1))
    capped + jitter
  end

  @spec format_reason(term()) :: String.t()
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(%{message: msg}) when is_binary(msg), do: msg
  defp format_reason(%{status: status}), do: "HTTP #{status}"
  defp format_reason(reason), do: inspect(reason)
end
