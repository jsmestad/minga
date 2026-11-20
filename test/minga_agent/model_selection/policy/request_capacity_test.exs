defmodule MingaAgent.ModelSelection.Policy.RequestCapacityTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ModelSelection.Policy.{Limits, RequestCapacity}

  test "applies both dedicated input and shared context limits without conflating them" do
    limits = limits(input: 80, context: 120, output: 50, request_output: 30)

    assert :ok = RequestCapacity.check(limits, {:provider_count, 80}, {:encoded, 40})

    assert {:error, :input_limit_exceeded} =
             RequestCapacity.check(limits, {:provider_count, 81}, {:encoded, 35})

    assert {:error, :context_reservation_exceeded} =
             RequestCapacity.check(limits, {:upper_bound, 80}, {:encoded, 41})

    assert {:error, :output_limit_exceeded} =
             RequestCapacity.check(limits, {:provider_count, 1}, {:encoded, 51})
  end

  test "distinguishes an omitted cap, estimated input, unavailable counting, and unavailable limits" do
    shared = limits(context: 100, request_output: 30)
    input_only = limits(input: 100)
    unknown = limits([])

    assert {:error, :missing_output_cap} =
             RequestCapacity.check(shared, {:provider_count, 1}, :omitted)

    assert {:error, :context_reservation_exceeded} =
             RequestCapacity.check(shared, {:provider_count, 71}, {:encoded, 29})

    assert {:error, :estimate_not_a_bound} =
             RequestCapacity.check(input_only, {:estimate, 2}, {:encoded, 10})

    assert {:error, {:unknown_input_size, :unsupported_route}} =
             RequestCapacity.check(input_only, {:unavailable, :unsupported_route}, {:encoded, 10})

    assert {:error, :missing_capacity} =
             RequestCapacity.check(unknown, {:provider_count, 1}, {:encoded, 10})

    assert :ok = RequestCapacity.check(input_only, {:upper_bound, 100}, :omitted)
  end

  test "the live provider ceiling fills unknown capacity but cannot raise configured capacity" do
    unknown = limits([])
    restricted = limits(context: 80)

    assert %{limits: ^unknown, observed_context: 100, decision: :ok} =
             RequestCapacity.assess(unknown, {:provider_count, 80}, {:encoded, 20}, 100)

    for {policy, observed} <- [{unknown, 80}, {restricted, 100}] do
      assert %{decision: {:error, :context_reservation_exceeded}} =
               RequestCapacity.assess(policy, {:provider_count, 80}, {:encoded, 20}, observed)
    end
  end

  defp limits(overrides) do
    attrs = Enum.into(overrides, %{input: nil, context: nil, output: nil, request_output: 10})
    {:ok, limits} = Limits.new(attrs)
    limits
  end
end
