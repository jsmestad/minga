defmodule MingaAgent.ModelLimitsTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ModelLimits

  describe "context_limit/1" do
    test "returns limit for known Claude models" do
      assert ModelLimits.context_limit("claude-sonnet-4") == 200_000
      assert ModelLimits.context_limit("claude-3-5-sonnet") == 200_000
    end

    test "returns limit for known OpenAI models" do
      assert ModelLimits.context_limit("gpt-4o") == 128_000
      assert ModelLimits.context_limit("gpt-4o-mini") == 128_000
    end

    test "returns limit for known Gemini models" do
      assert ModelLimits.context_limit("gemini-2.5-pro") == 1_048_576
    end

    test "returns nil for unknown models" do
      assert ModelLimits.context_limit("unknown-model") == nil
    end

    test "prefix matches versioned model names" do
      assert ModelLimits.context_limit("claude-sonnet-4-20250514") == 200_000
      assert ModelLimits.context_limit("gpt-4o-2024-08-06") == 128_000
    end
  end
end
