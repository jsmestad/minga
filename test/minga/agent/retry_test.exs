defmodule Minga.Agent.RetryTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Retry

  describe "retryable?/1" do
    test "429 rate limit is retryable" do
      assert Retry.retryable?(%{status: 429})
      assert Retry.retryable?(%{"status" => 429})
    end

    test "server errors are retryable" do
      for status <- [500, 502, 503, 529] do
        assert Retry.retryable?(%{status: status}), "expected #{status} to be retryable"
      end
    end

    test "client errors are not retryable" do
      for status <- [400, 401, 403, 404, 422] do
        refute Retry.retryable?(%{status: status}), "expected #{status} to not be retryable"
      end
    end

    test "network errors are retryable" do
      assert Retry.retryable?(:timeout)
      assert Retry.retryable?(:econnrefused)
      assert Retry.retryable?(:econnreset)
      assert Retry.retryable?(:closed)
    end

    test "DNS errors are not retryable" do
      refute Retry.retryable?(:nxdomain)
    end

    test "string messages containing retryable keywords" do
      assert Retry.retryable?("rate limit exceeded")
      assert Retry.retryable?("server overloaded")
      assert Retry.retryable?("connection reset")
      assert Retry.retryable?("request timeout")
    end

    test "unknown errors are not retryable" do
      refute Retry.retryable?(:something_else)
      refute Retry.retryable?("invalid request body")
    end
  end

  describe "with_retry/2" do
    test "returns immediately on success" do
      assert {:ok, :done} = Retry.with_retry(fn -> {:ok, :done} end)
    end

    test "returns immediately on non-retryable error" do
      counter = :counters.new(1, [:atomics])

      result =
        Retry.with_retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, %{status: 401}}
          end,
          max_retries: 3
        )

      assert {:error, %{status: 401}} = result
      assert :counters.get(counter, 1) == 1
    end

    test "retries on retryable error and eventually succeeds" do
      counter = :counters.new(1, [:atomics])

      result =
        Retry.with_retry(
          fn ->
            count = :counters.get(counter, 1) + 1
            :counters.put(counter, 1, count)

            if count < 3 do
              {:error, %{status: 429}}
            else
              {:ok, :recovered}
            end
          end,
          max_retries: 3,
          base_delay_ms: 1
        )

      assert {:ok, :recovered} = result
      assert :counters.get(counter, 1) == 3
    end

    test "gives up after max_retries" do
      counter = :counters.new(1, [:atomics])

      result =
        Retry.with_retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, %{status: 529}}
          end,
          max_retries: 2,
          base_delay_ms: 1
        )

      assert {:error, %{status: 529}} = result
      # 1 initial + 2 retries = 3 total attempts
      assert :counters.get(counter, 1) == 3
    end

    test "calls on_retry callback before each retry" do
      callback_log = :ets.new(:retry_log, [:ordered_set, :public])

      Retry.with_retry(
        fn -> {:error, %{status: 500}} end,
        max_retries: 2,
        base_delay_ms: 1,
        on_retry: fn attempt, delay_ms, reason ->
          :ets.insert(callback_log, {attempt, delay_ms, reason})
        end
      )

      entries = :ets.tab2list(callback_log)
      assert length(entries) == 2

      [{1, delay1, reason1}, {2, delay2, reason2}] = entries
      assert reason1 == "HTTP 500"
      assert reason2 == "HTTP 500"
      # Exponential backoff: second delay should be roughly 2x the first
      assert delay2 > delay1

      :ets.delete(callback_log)
    end

    test "zero max_retries means no retries" do
      counter = :counters.new(1, [:atomics])

      result =
        Retry.with_retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, %{status: 429}}
          end,
          max_retries: 0
        )

      assert {:error, %{status: 429}} = result
      assert :counters.get(counter, 1) == 1
    end
  end
end
