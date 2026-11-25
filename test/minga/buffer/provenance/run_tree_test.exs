defmodule Minga.Buffer.Provenance.RunTreeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Provenance.Run
  alias Minga.Buffer.Provenance.RunTree

  describe "rebuild_range/4" do
    property "replaces exactly the runs in the range, keeps the rest, and stays balanced with exact caches" do
      check all(
              runs <- list_of(run_gen(), min_length: 1, max_length: 200),
              a <- integer(0..199),
              b <- integer(0..199),
              keep <- list_of(boolean(), length: 200),
              max_runs: 300
            ) do
        runs = runs |> Enum.with_index(fn run, n -> %{run | id: [n * 2 + 1]} end)
        tree = Enum.reduce(runs, RunTree.new(), &RunTree.insert(&2, &1))
        [from, to] = Enum.sort([rem(a, length(runs)), rem(b, length(runs))])
        flags = List.to_tuple(keep)

        fun = fn %Run{id: [id]} = run ->
          index = div(id - 1, 2)
          if elem(flags, index), do: %{run | author: :you}
        end

        {rebuilt, seen} =
          RunTree.rebuild_range(tree, [from * 2 + 1], [to * 2 + 1], fn range ->
            {range |> Enum.map(fun) |> Enum.reject(&is_nil/1), length(range)}
          end)

        assert seen == to - from + 1

        expected =
          runs
          |> Enum.with_index()
          |> Enum.flat_map(fn {run, index} ->
            cond do
              index < from or index > to -> [run]
              elem(flags, index) -> [%{run | author: :you}]
              true -> []
            end
          end)

        assert RunTree.to_list(rebuilt) == expected
        assert RunTree.count(rebuilt) == length(expected)
        assert RunTree.size(rebuilt) == expected |> Enum.map(&Run.live_bytes/1) |> Enum.sum()

        assert RunTree.dead_bytes(rebuilt) ==
                 expected |> Enum.reject(& &1.live) |> Enum.map(& &1.bytes) |> Enum.sum()

        assert RunTree.height(rebuilt) <= 1.45 * :math.log2(length(expected) + 2)
      end
    end
  end

  describe "stretch/3" do
    property "returns the longest stretch of kept runs around a run" do
      check all(
              runs <- list_of(run_gen(), min_length: 1, max_length: 120),
              pick <- integer(0..119),
              max_runs: 300
            ) do
        runs = runs |> Enum.with_index(fn run, n -> %{run | id: [n + 1]} end)
        tree = RunTree.from_list(runs)
        at = rem(pick, length(runs))
        keep? = & &1.live
        run = Enum.at(runs, at)

        if keep?.(run) do
          first =
            runs |> Enum.take(at + 1) |> Enum.reverse() |> Enum.take_while(keep?) |> List.last()

          last = runs |> Enum.drop(at) |> Enum.take_while(keep?) |> List.last()
          assert RunTree.stretch(tree, run.id, keep?) == {first.id, last.id}
        else
          assert RunTree.stretch(tree, run.id, keep?) == nil
        end
      end
    end
  end

  defp run_gen do
    gen all(bytes <- integer(1..5), live <- boolean()) do
      %Run{
        id: [1],
        bytes: bytes,
        author: :unattributed,
        live: live,
        text: if(live, do: nil, else: "x")
      }
    end
  end
end
