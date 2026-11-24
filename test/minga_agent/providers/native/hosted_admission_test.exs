defmodule MingaAgent.Providers.Native.HostedAdmissionTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ModelSelection.Policy.Limits
  alias MingaAgent.ModelSelection.Policy.RequestCapacity
  alias MingaAgent.Providers.Native.HostedAdmission

  @sample_messages [%{role: "user", content: "Hello"}]

  defp permissive_limits do
    {:ok, limits} =
      Limits.new(%{context: 1_000_000, input: 500_000, output: 100_000, request_output: 4_096})

    limits
  end

  defp restrictive_limits do
    {:ok, limits} = Limits.new(%{context: 10, input: 5, output: 10, request_output: 4_096})
    limits
  end

  describe "upper_bound_tokens/1" do
    test "empty body returns 0" do
      assert HostedAdmission.upper_bound_tokens("") == 0
    end

    test "small JSON body returns a proportional upper bound" do
      body = JSON.encode!(@sample_messages)
      tokens = HostedAdmission.upper_bound_tokens(body)

      assert tokens == ceil(byte_size(body) / 2)
      assert tokens > 0
    end

    test "large body scales linearly" do
      body = String.duplicate("x", 10_000)
      assert HostedAdmission.upper_bound_tokens(body) == 5_000
    end

    test "odd-length body rounds up" do
      body = "abc"
      assert HostedAdmission.upper_bound_tokens(body) == 2
    end
  end

  describe "assess/4" do
    test "messages within budget return :ok" do
      limits = permissive_limits()

      authorize = fn _digest, %RequestCapacity{decision: :ok} ->
        :ok
      end

      assert :ok = HostedAdmission.assess(limits, 4_096, @sample_messages, authorize)
    end

    test "messages exceeding capacity return an error" do
      limits = restrictive_limits()

      authorize = fn _digest, %RequestCapacity{decision: {:error, reason}} ->
        {:error, reason}
      end

      assert {:error, {:request_admission_refused, _reason}} =
               HostedAdmission.assess(limits, 4_096, @sample_messages, authorize)
    end

    test "digest is the SHA-256 of the JSON-encoded messages" do
      limits = permissive_limits()
      expected_digest = :crypto.hash(:sha256, JSON.encode!(@sample_messages))

      authorize = fn digest, _evidence ->
        send(self(), {:digest, digest})
        :ok
      end

      HostedAdmission.assess(limits, 4_096, @sample_messages, authorize)
      assert_receive {:digest, ^expected_digest}
    end

    test "evidence carries the upper-bound measurement and encoded output cap" do
      limits = permissive_limits()
      encoded = JSON.encode!(@sample_messages)
      expected_tokens = ceil(byte_size(encoded) / 2)

      authorize = fn _digest, evidence ->
        send(self(), {:evidence, evidence})
        :ok
      end

      HostedAdmission.assess(limits, 2_048, @sample_messages, authorize)
      assert_receive {:evidence, %RequestCapacity{} = evidence}
      assert evidence.input == {:upper_bound, expected_tokens}
      assert evidence.output_cap == {:encoded, 2_048}
    end

    test "authorize rejection reason propagates to the error tuple" do
      limits = permissive_limits()

      authorize = fn _digest, _evidence ->
        {:error, :context_reservation_exceeded}
      end

      assert {:error, {:request_admission_refused, :context_reservation_exceeded}} =
               HostedAdmission.assess(limits, 4_096, @sample_messages, authorize)
    end
  end

  describe "RefusedError exception" do
    test "message includes the reason" do
      error = %HostedAdmission.RefusedError{reason: :input_limit_exceeded}
      assert Exception.message(error) =~ "input_limit_exceeded"
    end
  end
end
