defmodule MingaAgent.InferenceRouteRegistry.UsageLimitsTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ModelCandidate
  alias MingaAgent.ModelSelection.Credential.ApiKey
  alias MingaAgent.InferenceRouteRegistry.UsageLimits
  alias MingaAgent.Test.ModelSelectionFixture
  alias MingaAgent.UsageLimit

  @now ~U[2026-11-23 17:05:25Z]
  @limit %UsageLimit{
    service: "ChatGPT",
    plan: "pro",
    window_minutes: 10_080,
    resets_at: ~U[2026-11-25 17:01:06Z]
  }

  defp candidate(selection), do: ModelCandidate.new(selection, [], nil)

  setup do
    codex = ModelSelectionFixture.selection(request_provider: :openai_codex, model_id: "gpt-6.2")

    other_codex =
      ModelSelectionFixture.selection(request_provider: :openai_codex, model_id: "gpt-6.1")

    api =
      ModelSelectionFixture.selection(model_id: "gpt-6.2", credential: ApiKey.new("openai", :env))

    %{codex: codex, other_codex: other_codex, api: api}
  end

  test "a limit marks every model on the route and credential that hit it", ctx do
    limits = UsageLimits.observed(UsageLimits.new(), ctx.codex, @limit)
    candidates = Enum.map([ctx.codex, ctx.other_codex, ctx.api], &candidate/1)

    assert Enum.map(UsageLimits.annotate(limits, candidates, @now), & &1.usage_limit) ==
             [@limit, @limit, nil]
  end

  test "a limit stops showing once its reset passes or a request on the route succeeds", ctx do
    limits = UsageLimits.observed(UsageLimits.new(), ctx.codex, @limit)
    candidates = [candidate(ctx.codex)]

    assert [%ModelCandidate{usage_limit: nil}] =
             UsageLimits.annotate(limits, candidates, @limit.resets_at)

    succeeded = UsageLimits.request_succeeded(limits, ctx.other_codex)
    assert [%ModelCandidate{usage_limit: nil}] = UsageLimits.annotate(succeeded, candidates, @now)
  end

  test "a limit without a reset time stays until a request succeeds", ctx do
    limits = UsageLimits.observed(UsageLimits.new(), ctx.codex, UsageLimit.unknown("ChatGPT"))

    assert [%ModelCandidate{usage_limit: %UsageLimit{}}] =
             UsageLimits.annotate(limits, [candidate(ctx.codex)], ~U[2030-01-01 00:00:00Z])
  end

  test "a contributed route's limit is left to the route's own plan reports" do
    contributed =
      ModelSelectionFixture.selection(
        request_provider: :contributed,
        origin: {:contributed, "claude", "sonnet"},
        route_id: "claude/sonnet",
        model_id: "sonnet",
        model_provider: "claude"
      )

    limits = UsageLimits.observed(UsageLimits.new(), contributed, @limit)

    assert [%ModelCandidate{usage_limit: nil}] =
             UsageLimits.annotate(limits, [candidate(contributed)], @now)
  end
end
