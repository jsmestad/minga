defmodule Minga.Storyboard.FlowExplorerTest do
  @moduledoc """
  The flow explorer over the real editor: every key the active trie offers in every built scenario, plus the designed exits.

  Fails when a key crashes the editor, leaves no way back to plain editing within three presses of `esc` or `q` (invariant 2), lands a designed exit somewhere other than its target (invariants 1 and 7, the key half), or shows an error without a next step (invariant 4). Violations listed in `test/fixtures/storyboard/known_violations.tsv` are expected until their issue lands, and the list only shrinks. Screens the explorer cannot classify are printed with the key path that reached them.
  """

  use ExUnit.Case, async: true

  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Explorer
  alias Minga.Test.Storyboard.Inventory
  alias Minga.Test.Storyboard.Keys
  alias Minga.Test.Storyboard.KnownViolations
  alias Minga.Test.Storyboard.Registry

  @moduletag :storyboard
  @moduletag timeout: 300_000

  setup_all do
    edges = Enum.flat_map(Registry.built(), &Explorer.edges/1)
    %{edges: edges, violations: violations(edges)}
  end

  test "the explorer presses every key the active trie offers", %{edges: edges} do
    from_plain = Enum.filter(edges, &(&1.from == Registry.home()))
    leader_paths = Enum.count(from_plain, &String.starts_with?(&1.keys, "SPC "))

    assert Enum.count_until(from_plain, 101) > 100,
           "expected the Vim normal and leader keys, got #{Enum.count(from_plain)}"

    assert leader_paths > 50, "expected every leader binding, got #{leader_paths}"
  end

  test "no key crashes the editor", %{edges: edges} do
    crashed =
      for %{to: :crashed} = edge <- edges, do: "#{edge.from}: #{edge.keys}: #{edge.signature}"

    assert crashed == [], "keys that crashed the editor:\n" <> Enum.join(crashed, "\n")
  end

  test "every flow-graph violation is listed, and every listed one still happens", %{
    violations: violations
  } do
    found = MapSet.new(violations, &KnownViolations.identity/1)
    known = MapSet.new(KnownViolations.rows(), &KnownViolations.identity/1)

    new =
      for violation <- violations,
          not MapSet.member?(known, KnownViolations.identity(violation)),
          do: violation

    assert new == [], """
    New flow-graph violations. Fix them, or file a bug and fix it; never add rows to #{KnownViolations.path()}.
    #{Enum.map_join(new, "\n", &"  #{&1.invariant} #{&1.scenario} #{&1.keys}: #{&1.detail}")}
    """

    stale =
      for row <- KnownViolations.rows(),
          not MapSet.member?(found, KnownViolations.identity(row)),
          do: row

    assert stale == [], """
    These listed violations no longer happen. Remove their rows from #{KnownViolations.path()}:
    #{Enum.map_join(stale, "\n", &"  #{&1.invariant} #{&1.scenario} #{&1.keys} (##{&1.issue})")}
    """
  end

  test "every listed violation names an issue and a reason" do
    for row <- KnownViolations.rows() do
      assert row.issue > 0 and row.reason != "", "incomplete row: #{inspect(row)}"

      assert match?({:ok, %Entry{}}, Registry.fetch(row.scenario)),
             "unknown scenario in row: #{inspect(row)}"
    end
  end

  test "commands the explorer skips are bound and named with a reason", %{edges: edges} do
    skipped = for %{to: :skipped, command: command} <- edges, uniq: true, do: command
    assert skipped != [], "the skip list matches no binding; remove stale entries"
    assert Enum.all?(Explorer.skipped_commands(), fn {_command, reason} -> reason != "" end)
  end

  test "reports the screens the explorer could not classify", %{edges: edges} do
    unknown =
      edges
      |> Enum.filter(&(&1.to == :unknown))
      |> Enum.uniq_by(& &1.signature)
      |> Enum.map(&"  #{&1.signature}  (#{&1.from}: #{&1.keys})")

    no_change =
      for %{changed?: false, to: to} = edge <- edges,
          to not in [:skipped, :crashed],
          String.starts_with?(edge.keys, "SPC "),
          do: "#{edge.from}: #{edge.keys}"

    IO.puts("""

    Flow explorer: #{length(edges)} key paths from #{edges |> Enum.uniq_by(& &1.from) |> length()} scenarios
    Unaccounted-for screens (#{length(unknown)}), with the first key path that reached each:
    #{Enum.join(unknown, "\n")}
    Leader keys that changed nothing in the frame (#{length(no_change)}): #{Enum.join(no_change, ", ")}
    """)

    assert is_list(unknown)
  end

  @spec violations([Explorer.edge()]) :: [map()]
  defp violations(edges) do
    way_out =
      for %{way_out: {:stranded, detail}} = edge <- edges,
          do: violation("way_out", edge, detail)

    silent_errors =
      for %{silent_errors: [_ | _] = titles} = edge <- edges,
          do: violation("next_step", edge, "errors without an action: #{inspect(titles)}")

    way_out ++ silent_errors ++ exit_violations(edges)
  end

  # Invariants 1 and 7, the key half: a designed exit between two built scenarios lands on its target.
  @spec exit_violations([Explorer.edge()]) :: [map()]
  defp exit_violations(edges) do
    built = MapSet.new(Registry.built(), & &1.id)
    by_path = Map.new(edges, &{{&1.from, &1.keys}, &1})

    for from <- built,
        exit <- from |> Inventory.fetch!() |> Inventory.exits(),
        MapSet.member?(built, exit["to"]),
        {:ok, _steps} <- [Keys.parse(exit["key"])],
        edge = Map.get(by_path, {from, String.trim(exit["key"])}),
        edge != nil and edge.to != exit["to"],
        do:
          violation(
            "exit",
            edge,
            "expected #{exit["to"]}, landed on #{inspect(edge.to)} (#{edge.signature})"
          )
  end

  @spec violation(String.t(), Explorer.edge(), String.t()) :: map()
  defp violation(invariant, edge, detail),
    do: %{invariant: invariant, scenario: edge.from, keys: edge.keys, detail: detail}
end
