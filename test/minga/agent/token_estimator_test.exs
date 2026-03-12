defmodule Minga.Agent.TokenEstimatorTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.TokenEstimator

  doctest Minga.Agent.TokenEstimator

  describe "estimate/1" do
    test "empty message list returns 0" do
      assert TokenEstimator.estimate([]) == 0
    end

    test "single system message includes system overhead" do
      messages = [%{role: "system", content: "You are helpful."}]
      result = TokenEstimator.estimate(messages)
      # ~16 chars / 3.5 ≈ 5 + 4 (msg overhead) + 8 (system overhead) = 17
      assert result > 10
      assert result < 25
    end

    test "multiple messages accumulate" do
      messages = [
        %{role: "system", content: "You are helpful."},
        %{role: "user", content: "Hello, how are you?"},
        %{role: "assistant", content: "I'm doing well, thank you!"}
      ]

      result = TokenEstimator.estimate(messages)
      # Should be > single message
      assert result > 20
    end

    test "long content produces proportionally more tokens" do
      short = [%{role: "user", content: "Hi"}]
      long = [%{role: "user", content: String.duplicate("word ", 1000)}]

      short_est = TokenEstimator.estimate(short)
      long_est = TokenEstimator.estimate(long)

      assert long_est > short_est * 10
    end

    test "handles list-style content parts" do
      messages = [
        %{role: "user", content: [%{text: "Hello "}, %{text: "world"}]}
      ]

      result = TokenEstimator.estimate(messages)
      assert result > 0
    end

    test "handles messages without content" do
      messages = [%{role: "assistant"}]
      result = TokenEstimator.estimate(messages)
      # Just the overhead
      assert result == 4
    end
  end

  describe "estimate_string/1" do
    test "short string" do
      assert TokenEstimator.estimate_string("Hello") >= 1
    end

    test "empty string returns 1 (minimum)" do
      assert TokenEstimator.estimate_string("") == 1
    end

    test "long string scales linearly" do
      short = TokenEstimator.estimate_string("hello")
      long = TokenEstimator.estimate_string(String.duplicate("hello ", 100))
      assert long > short * 50
    end
  end
end
