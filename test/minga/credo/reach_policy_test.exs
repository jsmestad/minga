Code.require_file("credo/checks/dependency_direction_check.exs")

defmodule Minga.Credo.ReachPolicyTest do
  @moduledoc """
  `.reach.exs` enforces runtime purity for the Layer 0 modules that `Minga.Credo.DependencyDirectionCheck` enforces dependency direction for. Both tools must agree on which modules those are.
  """

  use ExUnit.Case, async: true

  alias Minga.Credo.DependencyDirectionCheck

  @policy_path ".reach.exs"

  setup_all do
    {policy, _bindings} = Code.eval_file(@policy_path)
    %{allowed: get_in(policy, [:effects, :allowed]) || []}
  end

  test "the effects policy names exactly the Credo Layer 0 modules, each with a child-module twin",
       %{
         allowed: allowed
       } do
    patterns = Enum.map(allowed, &elem(&1, 0))
    exact = patterns |> Enum.reject(&String.ends_with?(&1, ".*")) |> MapSet.new()

    twins =
      patterns
      |> Enum.filter(&String.ends_with?(&1, ".*"))
      |> Enum.map(&String.trim_trailing(&1, ".*"))
      |> MapSet.new()

    credo = MapSet.new(DependencyDirectionCheck.layer_0_prefixes())

    assert MapSet.equal?(exact, credo),
           "Layer 0 modules missing from .reach.exs: #{inspect(MapSet.difference(credo, exact) |> Enum.sort())}; extra in .reach.exs: #{inspect(MapSet.difference(exact, credo) |> Enum.sort())}"

    assert MapSet.equal?(twins, credo),
           "Every Layer 0 entry needs a `.*` twin so child modules are covered as Credo covers them; missing twins: #{inspect(MapSet.difference(credo, twins) |> Enum.sort())}"
  end

  test "every Layer 0 module is held to the same effect allowance", %{allowed: allowed} do
    allowances =
      allowed |> Enum.map(fn {_pattern, effects} -> Enum.sort(effects) end) |> Enum.uniq()

    assert allowances == [[:exception, :io, :pure, :unknown]],
           "Layer 0 purity is one rule, not a per-module negotiation: #{inspect(allowances)}"
  end
end
