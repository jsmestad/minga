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

  test "the inventory covers a focused staged Diff Review in Vim and in CUA", %{
    inventory: inventory
  } do
    overlaid =
      for %{overlay: :diff_review} = b <- inventory, into: MapSet.new(), do: {b.scope, b.state}

    assert overlaid == MapSet.new([{:agent, :normal}, {:agent, :cua}])
  end

  test "the inventory covers the composer's start remedy under every remedy", %{
    inventory: inventory
  } do
    assert %{scope: :agent, state: :input_normal, overlay: :none, keys: [{13, 0}]} =
             Enum.find(
               inventory,
               &(&1.command == :agent_submit_or_newline and &1.state == :input_normal)
             )
  end

  test "overlay allow-list entries match real bindings in their overlay", %{inventory: inventory} do
    unmatched =
      for {{overlay, state}, conventions} <- KeyGrammar.overlay_conventions(),
          {key, commands, _why} <- conventions,
          not Enum.any?(inventory, fn binding ->
            binding.overlay == overlay and binding.state == state and binding.keys == [key] and
              binding.command in commands
          end),
          do: {overlay, state, key}

    assert unmatched == []
  end

  test "no keymap context binds a forbidden chord, including a focused staged Diff Review", %{
    violations: violations
  } do
    forbidden = Enum.filter(violations, &(&1.rule == :forbidden_chord))

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

  # Classifies synthetic bindings; a live prompt is mapped explicitly because no built-in scope declares one yet.
  defp rules_for(bindings) do
    contexts = %{
      {:editor, :cua} => :typing,
      {:git_status, :cua} => :special_cua,
      {:agent, :normal} => :special,
      {:agent, :insert} => :typing,
      {:agent, :cua} => :typing,
      {:picker, :cua} => :picker
    }

    bindings
    |> Enum.map(fn {scope, state, overlay, keys, command} ->
      %{
        scope: scope,
        state: state,
        overlay: overlay,
        keys: keys,
        command: command,
        origin: :effective
      }
    end)
    |> KeyGrammar.violations([], contexts)
    |> Enum.map(& &1.rule)
  end

  defp rules_for(scope, state, keys, command),
    do: rules_for([{scope, state, :none, keys, command}])

  describe "the CUA profile (ADR-0007)" do
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

  describe "a focused staged Diff Review" do
    test "a key the review rebinds is not a second meaning underneath it" do
      assert rules_for([
               {:agent, :normal, :none, [{?y, 0}], :agent_copy_code_block},
               {:agent, :normal, :diff_review, [{?y, 0}], :agent_accept_hunk}
             ]) == []
    end

    test "a key with two meanings inside the review is a duplicate" do
      assert rules_for([
               {:agent, :normal, :diff_review, [{?y, 0}], :agent_accept_hunk},
               {:agent, :normal, :diff_review, [{?y, 0}], :agent_copy_code_block}
             ]) == [:duplicate_key]
    end

    test "listed review chords pass in the CUA review" do
      for {keys, command} <- [
            {[{13, @cmd}], :agent_accept_hunk},
            {[{13, @ctrl}], :agent_accept_hunk},
            {[{127, @cmd ||| @shift}], :agent_reject_all_hunks},
            {[{57_353, @alt}], :agent_next_code_block}
          ] do
        assert rules_for([{:agent, :cua, :diff_review, keys, command}]) == [], inspect(keys)
      end
    end

    test "review chords the allow-list does not cover still fail" do
      for {label, state, overlay, keys, command, rule} <- [
            {"listed chord outside the review", :cua, :none, [{13, @cmd}], :agent_accept_hunk,
             :platform_key},
            {"listed ⌃ chord outside the review", :cua, :none, [{13, @ctrl}], :agent_accept_hunk,
             :unconventional_modifier},
            {"listed chord with another meaning", :cua, :diff_review, [{13, @cmd}],
             :agent_copy_message, :platform_key},
            {"listed chord in the Vim review", :normal, :diff_review, [{13, @ctrl}],
             :agent_accept_hunk, :normal_mode_modifier},
            {"unlisted chord in the review", :cua, :diff_review, [{?g, @ctrl}],
             :agent_accept_hunk, :unconventional_modifier},
            {"function key in the review", :cua, :diff_review, [{0xF70A, 0}],
             :agent_next_code_block, :forbidden_chord}
          ] do
        assert rules_for([{:agent, state, overlay, keys, command}]) == [rule], label
      end
    end
  end

  defp format(violations) do
    Enum.map_join(violations, "\n", fn v ->
      "  #{v.rule}  #{v.scope}/#{v.state}  #{v.key}  #{v.command}  (#{v.reason})"
    end)
  end
end
