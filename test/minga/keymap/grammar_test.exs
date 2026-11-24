defmodule Minga.Keymap.GrammarTest do
  @moduledoc """
  Guards the key grammar (design principle 11) against drift.

  The test walks every built-in binding without starting the Editor (see `Minga.Test.KeyGrammar`), classifies violations into named rule ids, and fails on any violation that is not in `test/fixtures/keymap/grammar_baseline.tsv`. It also fails on baseline rows the code no longer violates, so fixed rows leave the baseline in the same change.

  Never add baseline rows. To prune fixed rows run:

      MINGA_WRITE_KEY_GRAMMAR_BASELINE=1 mix test test/minga/keymap/grammar_test.exs

  The writer keeps only rows already in the baseline. It writes every current violation only when the file does not exist.
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias Minga.Test.KeyGrammar

  @shift 0x01
  @ctrl 0x02
  @alt 0x04
  @cmd 0x08

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

  # Prompt and terminal conventions whose feature has not shipped yet, with the ticket that binds each one.
  # Remove a row when its ticket binds the key; the test fails until you do.
  @pending_conventions MapSet.new([
                         {{?t, @ctrl}, :picker},
                         {{?q, @ctrl}, :picker},
                         {{?\\, @ctrl}, :terminal},
                         {{?n, @ctrl}, :terminal},
                         {{?., @ctrl}, :terminal}
                       ])

  test "prompt and terminal allow-list entries match real bindings", %{inventory: inventory} do
    bound =
      for %{scope: scope, state: state, keys: keys, command: command, origin: :effective} <-
            inventory,
          context = KeyGrammar.context_for(scope, state),
          key <- keys,
          do: {key, context, command}

    unmatched =
      for {key, contexts, commands, _why} <- KeyGrammar.modifier_conventions(),
          context <- contexts,
          context in [:picker, :terminal],
          not Enum.any?(bound, fn {bound_key, bound_context, command} ->
            bound_key == key and bound_context == context and
              (commands == :any or command in commands)
          end),
          into: MapSet.new(),
          do: {key, context}

    # ⌃T pins (#4056), ⌃Q sends to quickfix (#4059), ⌃\ ⌃N leaves the terminal and ⌃. opens its act menu (#4060).
    assert unmatched == @pending_conventions
  end

  test "no keymap context binds a forbidden chord, including a focused staged Diff Review" do
    forbidden =
      KeyGrammar.overlay_inventory()
      |> KeyGrammar.violations([])
      |> Enum.filter(&(&1.rule == :forbidden_chord))

    assert forbidden == [], """
    Rule 6 has no exceptions: no function keys, three-modifier chords, or two of ⌃ ⌥ ⌘ together.

    #{format(forbidden)}
    """
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

  describe "the CUA profile (ADR-0007)" do
    # Classifies one synthetic binding; a live prompt is mapped explicitly because no built-in scope declares one yet.
    defp rules_for(scope, state, keys, command) do
      binding = %{scope: scope, state: state, keys: keys, command: command, origin: :effective}

      contexts = %{
        {:editor, :cua} => :typing,
        {:git_status, :cua} => :special_cua,
        {:agent, :insert} => :typing,
        {:picker, :cua} => :picker
      }

      [binding]
      |> KeyGrammar.violations([], contexts)
      |> Enum.map(& &1.rule)
    end

    test "listed desktop conventions pass in CUA states" do
      for {scope, keys, command} <- [
            {:editor, [{?c, @cmd}], :yank_visual_selection},
            {:editor, [{?z, @cmd ||| @shift}], :redo},
            {:editor, [{?a, @ctrl}], :select_all},
            {:editor, [{?p, @ctrl ||| @shift}], :command_palette},
            {:git_status, [{?y, @ctrl}], :redo}
          ] do
        assert rules_for(scope, :cua, keys, command) == [], "#{inspect(keys)} #{command}"
      end
    end

    test "violations the profile does not cover still fail" do
      for {label, scope, state, keys, command, rule} <- [
            {"unlisted ⌘ key", :editor, :cua, [{?b, @cmd}], :toggle_bold, :platform_key},
            {"unlisted ⌃ key", :editor, :cua, [{?b, @ctrl}], :toggle_bold,
             :unconventional_modifier},
            {"listed key with another meaning", :git_status, :cua, [{?c, @cmd}], :git_commit_open,
             :platform_key},
            {"listed key outside a CUA state", :agent, :insert, [{?a, @ctrl}], :select_all,
             :editing_collision},
            {"three-modifier chord", :editor, :cua, [{?z, @ctrl ||| @alt ||| @shift}], :redo,
             :forbidden_chord},
            {"⌃⌘ chord", :editor, :cua, [{?c, @ctrl ||| @cmd}], :yank_visual_selection,
             :forbidden_chord},
            {"⌥⌘ chord", :editor, :cua, [{?z, @alt ||| @cmd}], :undo, :forbidden_chord},
            {"editing collision in a live prompt", :picker, :cua, [{?a, @ctrl}], :select_all,
             :editing_collision}
          ] do
        assert rules_for(scope, state, keys, command) == [rule], label
      end
    end
  end

  defp format(violations) do
    Enum.map_join(violations, "\n", fn v ->
      "  #{v.rule}  #{v.scope}/#{v.state}  #{v.key}  #{v.command}  (#{v.reason})"
    end)
  end
end
