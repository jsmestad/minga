defmodule Minga.Conformance.MacrosTest do
  # Conformance tests invoke nvim as an OS process, so they run serially to avoid erl_child_setup EPIPE races.
  use Minga.Test.ConformanceCase, async: false

  # Neovim's headless APIs (feedkeys, :normal!, :source!) cannot record macros
  # to registers. All macro scenarios pre-populate the register and test replay
  # conformance. Minga's macro recording is tested separately in unit tests.

  @compare [:content, :cursor, :mode]

  @scenarios [
    %{
      name: "replay simple delete macro",
      type: :macro,
      content: "abcd\nabcd",
      cursor: %{line: 0, col: 0},
      register_setup: %{"a" => "0x$x"},
      keys: "@aj@a",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still leaves the cursor one column too far right after `$x`.",
        failures: [:cursor],
        actual: %{line: 1, col: 2}
      }
    },
    %{
      name: "replay macro with insert mode content",
      type: :macro,
      content: "one\ntwo\nthree",
      cursor: %{line: 0, col: 0},
      register_setup: %{"a" => "I-- \x1b"},
      keys: "@aj@a",
      compare: @compare
    },
    %{
      name: "replay macro with count",
      type: :macro,
      content: "one\ntwo\nthree\nfour",
      cursor: %{line: 0, col: 0},
      register_setup: %{"a" => "I-- \x1bj"},
      keys: "3@a",
      compare: @compare
    },
    %{
      name: "replay last macro with @@",
      type: :macro,
      content: "one\ntwo\nthree",
      cursor: %{line: 0, col: 0},
      register_setup: %{"a" => "I-- \x1b"},
      keys: "@aj@@",
      compare: @compare
    },
    %{
      name: "replay yank and paste macro",
      type: :macro,
      content: "hello\nworld",
      cursor: %{line: 0, col: 0},
      register_setup: %{"a" => "yyp"},
      keys: "@a",
      compare: @compare
    },
    %{
      name: "empty macro replay is no-op",
      type: :macro,
      content: "one\ntwo",
      cursor: %{line: 0, col: 0},
      register_setup: %{"a" => ""},
      keys: "@a",
      compare: @compare
    },
    %{
      name: "macro replay on last line does not crash",
      type: :macro,
      content: "one\ntwo",
      cursor: %{line: 1, col: 0},
      register_setup: %{"a" => "0x$x"},
      keys: "@a",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still leaves the cursor one column too far right after `$x`.",
        failures: [:cursor],
        actual: %{line: 1, col: 1}
      }
    }
  ]

  @spec scenarios() :: [Minga.Test.NeovimOracle.scenario()]
  def scenarios, do: @scenarios

  for scenario <- @scenarios do
    if :known_divergence in Map.get(scenario, :tags, []) do
      @tag :known_divergence
    end

    @tag scenario: scenario.name
    test scenario.name, %{oracle_results: oracle_results} do
      assert_conforms(unquote(Macro.escape(scenario)), oracle_results)
    end
  end
end
