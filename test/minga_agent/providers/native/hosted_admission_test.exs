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

  defp encoded_request(messages), do: JSON.encode!(%{messages: messages, tools: []})

  # Measures a request through assess/6 and returns its upper-bound token count.
  defp measured(messages, tools, provider) do
    authorize = fn digest, evidence ->
      send(self(), {:assessed, digest, evidence})
      :ok
    end

    :ok = HostedAdmission.assess(permissive_limits(), 4_096, messages, tools, provider, authorize)
    assert_receive {:assessed, digest, %RequestCapacity{input: {:upper_bound, tokens}}}
    {tokens, digest}
  end

  defp screenshot(fill),
    do: ReqLLM.Message.ContentPart.image(:binary.copy(<<fill>>, 600_000), "image/png")

  defp with_image(image) do
    [
      %ReqLLM.Message{
        role: :user,
        content: [ReqLLM.Message.ContentPart.text("what is this?"), image]
      }
    ]
  end

  describe "images" do
    test "count the documented per-image maximum on Anthropic and OpenAI routes, not their bytes" do
      text_only = [
        %ReqLLM.Message{role: :user, content: [ReqLLM.Message.ContentPart.text("what is this?")]}
      ]

      for {provider, bound} <- [anthropic: 4_784, openai: 48_169] do
        {base, _} = measured(text_only, [], provider)
        {tokens, _} = measured(with_image(screenshot(1)), [], provider)
        assert (tokens - base) in bound..(bound + 128)
      end
    end

    test "keep the byte measure on routes without a documented maximum" do
      {tokens, _} = measured(with_image(screenshot(1)), [], :openai_codex)
      assert tokens > 400_000
    end

    test "still change the digest when only the image bytes differ" do
      {_, first} = measured(with_image(screenshot(1)), [], :anthropic)
      {_, second} = measured(with_image(screenshot(2)), [], :anthropic)
      refute first == second
    end

    test "a 600 KB screenshot is admitted within a 200k context on Anthropic" do
      {:ok, limits} =
        Limits.new(%{context: 200_000, input: 200_000, output: 64_000, request_output: 4_096})

      authorize = fn _digest, %RequestCapacity{decision: decision} ->
        if decision == :ok, do: :ok, else: decision
      end

      assert :ok =
               HostedAdmission.assess(
                 limits,
                 4_096,
                 with_image(screenshot(1)),
                 [],
                 :anthropic,
                 authorize
               )
    end
  end

  describe "tool declarations" do
    test "add their encoded schemas to the measured size" do
      tool =
        ReqLLM.Tool.new!(
          name: "read_file",
          description: String.duplicate("Reads a file from the project. ", 200),
          parameter_schema: [path: [type: :string, required: true, doc: "Path to read"]],
          callback: fn _ -> {:ok, ""} end
        )

      {without, _} = measured(@sample_messages, [], :anthropic)
      {with_tool, _} = measured(@sample_messages, [tool], :anthropic)
      assert with_tool - without > 2_000
    end
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

      assert :ok = HostedAdmission.assess(limits, 4_096, @sample_messages, [], :openai, authorize)
    end

    test "messages exceeding capacity return an error" do
      limits = restrictive_limits()

      authorize = fn _digest, %RequestCapacity{decision: {:error, reason}} ->
        {:error, reason}
      end

      assert {:error, {:request_admission_refused, _reason}} =
               HostedAdmission.assess(limits, 4_096, @sample_messages, [], :openai, authorize)
    end

    test "digest is the SHA-256 of the JSON-encoded request" do
      limits = permissive_limits()
      expected_digest = :crypto.hash(:sha256, encoded_request(@sample_messages))

      authorize = fn digest, _evidence ->
        send(self(), {:digest, digest})
        :ok
      end

      HostedAdmission.assess(limits, 4_096, @sample_messages, [], :openai, authorize)
      assert_receive {:digest, ^expected_digest}
    end

    test "evidence carries the upper-bound measurement and encoded output cap" do
      limits = permissive_limits()
      expected_tokens = ceil(byte_size(encoded_request(@sample_messages)) / 2)

      authorize = fn _digest, evidence ->
        send(self(), {:evidence, evidence})
        :ok
      end

      HostedAdmission.assess(limits, 2_048, @sample_messages, [], :openai, authorize)
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
               HostedAdmission.assess(limits, 4_096, @sample_messages, [], :openai, authorize)
    end
  end
end
