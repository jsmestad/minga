defmodule Minga.Keymap.GrammarTest do
  @moduledoc """
  Guards the key grammar (design principle 11) against drift.

  The test walks every built-in binding without starting the Editor (see `Minga.Test.KeyGrammar`), classifies violations into named rule ids, and fails on any violation that is not in `test/fixtures/keymap/grammar_baseline.tsv`. It also fails on baseline rows the code no longer violates, so fixed rows leave the baseline in the same change.

  Never add baseline rows. To prune fixed rows run:

      MINGA_WRITE_KEY_GRAMMAR_BASELINE=1 mix test test/minga/keymap/grammar_test.exs

  The writer keeps only rows already in the baseline. It writes every current violation only when the file does not exist.
  """

  use ExUnit.Case, async: true

  alias Minga.Test.KeyGrammar

  @fixtures Path.expand("../../fixtures/keymap", __DIR__)
  @baseline_path Path.join(@fixtures, "grammar_baseline.tsv")
  @doom_path Path.join(@fixtures, "doom_conventions.tsv")

  setup_all do
    inventory = KeyGrammar.inventory()
    doom = KeyGrammar.read_doom(@doom_path)
    violations = KeyGrammar.violations(inventory, doom)

    if System.get_env("MINGA_WRITE_KEY_GRAMMAR_BASELINE") == "1" do
      KeyGrammar.write_baseline!(@baseline_path, violations)
    end

    %{inventory: inventory, doom: doom, violations: violations}
  end

  test "the inventory covers the leader, Vim normal mode and every built-in scope", %{
    inventory: inventory
  } do
    scopes = inventory |> Enum.map(& &1.scope) |> Enum.uniq() |> Enum.sort()

    assert scopes ==
             Enum.sort([:leader | Enum.map(Minga.Keymap.Scope.builtin_modules(), & &1.name())])
  end

  test "every scope and vim state with bindings has a grammar context", %{inventory: inventory} do
    assert KeyGrammar.unclassified(inventory) == [],
           "Classify these {scope, vim state} pairs in Minga.Test.KeyGrammar @contexts"
  end

  test "rows marked matches use the Doom key itself", %{doom: doom} do
    mismatched = for %{status: :matches} = row <- doom, row.minga_key != row.doom_key, do: row
    assert mismatched == []
  end

  test "no key grammar violation exists outside the baseline", %{violations: violations} do
    baseline = @baseline_path |> KeyGrammar.read_baseline() |> MapSet.new(&KeyGrammar.identity/1)
    new = Enum.reject(violations, &MapSet.member?(baseline, KeyGrammar.identity(&1)))

    assert new == [], """
    #{length(new)} binding(s) break the key grammar (AGENTS.md "Key grammar"):

    #{format(new)}

    Fix the binding. Never add rows to #{Path.relative_to_cwd(@baseline_path)}.
    """
  end

  test "the baseline lists only violations that still exist", %{violations: violations} do
    current = MapSet.new(violations, &KeyGrammar.identity/1)

    stale =
      @baseline_path
      |> KeyGrammar.read_baseline()
      |> Enum.reject(&MapSet.member?(current, KeyGrammar.identity(&1)))

    assert stale == [], """
    #{length(stale)} baseline row(s) no longer apply. Remove them:

    #{format(stale)}

    Run MINGA_WRITE_KEY_GRAMMAR_BASELINE=1 mix test #{Path.relative_to_cwd(__ENV__.file)}
    """
  end

  defp format(violations) do
    Enum.map_join(violations, "\n", fn v ->
      "  #{v.rule}  #{v.scope}/#{v.state}  #{v.key}  #{v.command}  (#{v.reason})"
    end)
  end
end
