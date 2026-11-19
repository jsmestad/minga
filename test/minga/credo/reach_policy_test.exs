Code.require_file("credo/checks/dependency_direction_check.exs")

defmodule Minga.Credo.ReachPolicyTest do
  @moduledoc """
  `.reach.exs` mirrors global Layer 0 foundations and explicitly protects selected pure Agent-internal Level 0 values without promoting them into the global layer.
  """

  use ExUnit.Case, async: true

  alias Minga.Credo.DependencyDirectionCheck

  @policy_path ".reach.exs"
  @agent_pure_prefixes ["MingaAgent.Session.Transcript"]

  setup_all do
    {policy, _bindings} = Code.eval_file(@policy_path)
    %{policy: policy, allowed: get_in(policy, [:effects, :allowed]) || []}
  end

  test "the effects policy names exactly global foundations and explicit pure Agent values, each with a child twin",
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

    global = MapSet.new(DependencyDirectionCheck.layer_0_prefixes())
    agent = MapSet.new(@agent_pure_prefixes)
    assert MapSet.disjoint?(global, agent)
    credo = MapSet.union(global, agent)

    assert MapSet.equal?(exact, credo),
           "Layer 0 modules missing from .reach.exs: #{inspect(MapSet.difference(credo, exact) |> Enum.sort())}; extra in .reach.exs: #{inspect(MapSet.difference(exact, credo) |> Enum.sort())}"

    assert MapSet.equal?(twins, credo),
           "Every Layer 0 entry needs a `.*` twin so child modules are covered as Credo covers them; missing twins: #{inspect(MapSet.difference(credo, twins) |> Enum.sort())}"
  end

  test "global foundations and explicit pure Agent values share the same effect allowance", %{
    allowed: allowed
  } do
    allowances =
      allowed |> Enum.map(fn {_pattern, effects} -> Enum.sort(effects) end) |> Enum.uniq()

    assert allowances == [[:exception, :pure, :unknown]],
           "Layer 0 purity is one rule, not a per-module negotiation: #{inspect(allowances)}"
  end

  @tag :tmp_dir
  test "rejects logging and real I/O but accepts pure iodata operations", %{
    policy: policy,
    tmp_dir: dir
  } do
    path = Path.join(dir, "probe.ex")

    File.write!(path, """
    defmodule Minga.Core.ReachProbe do
      alias Minga.Log, as: Log
      require Logger

      def convert(parts), do: :binary.list_to_bin(parts)
      def convert_iodata(parts), do: :erlang.iolist_to_binary(parts)
      def size(parts), do: :erlang.iolist_size(parts)
      def write(text), do: IO.puts(text)
      def direct_log(text), do: Logger.warning(text)
      def wrapped_log(text), do: Log.warning(:config, text)
      def shell(), do: System.cmd("echo", ["example"])
    end
    """)

    project = Reach.Project.from_sources([path], source_only: true)

    assert %{status: "failed", violations: violations} =
             Reach.Check.Architecture.run(project, policy)

    assert Enum.sort(
             for violation <- violations,
                 do: {violation.type, violation.function || violation.call}
           ) ==
             [
               {:effect_policy, "direct_log/1"},
               {:effect_policy, "shell/0"},
               {:effect_policy, "write/1"},
               {:forbidden_call, "Minga.Log.warning/2"}
             ]
  end
end
