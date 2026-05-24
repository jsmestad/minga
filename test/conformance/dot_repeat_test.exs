defmodule Minga.Conformance.DotRepeatTest do
  # Conformance tests invoke nvim as an OS process, so they run serially to avoid erl_child_setup EPIPE races.
  use Minga.Test.ConformanceCase, async: false

  @compare [:content, :cursor, :mode]

  @scenarios [
    %{
      name: "dot repeats dw",
      type: :operator,
      content: "one two three four",
      cursor: %{line: 0, col: 0},
      keys: "dw.",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still deletes the wrong trailing span for `dw`, compounding on repeat.",
        failures: [:content],
        actual: %{content: "hree four"}
      }
    },
    %{
      name: "dot repeats dd",
      type: :operator,
      content: "one\ntwo\nthree",
      cursor: %{line: 0, col: 0},
      keys: "dd.",
      compare: @compare
    },
    %{
      name: "dot repeats cw with replacement text",
      type: :operator,
      content: "one two three",
      cursor: %{line: 0, col: 0},
      keys: "cwhello<Esc>w.",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason:
          "Minga still changes the wrong trailing span for `cw`, compounding on dot repeat.",
        failures: [:content, :cursor],
        actual: %{content: "hellowo hello", line: 0, col: 12}
      }
    },
    %{
      name: "dot repeats insert",
      type: :operator,
      content: "hello",
      cursor: %{line: 0, col: 0},
      keys: "itext<Esc>.",
      compare: @compare
    },
    %{
      name: "dot with count override",
      type: :operator,
      content: "one two three four five",
      cursor: %{line: 0, col: 0},
      keys: "dw3.",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason:
          "Minga still deletes the wrong trailing span for `dw`, count override compounds the error.",
        failures: [:content],
        actual: %{content: "ive"}
      }
    },
    %{
      name: "dot repeats right shift",
      type: :operator,
      content: "one\ntwo\nthree",
      cursor: %{line: 0, col: 0},
      keys: ">>j.",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason:
          "Minga indents with 2 spaces instead of Neovim's default tab, and leaves the cursor shifted right.",
        failures: [:content, :cursor],
        actual: %{content: "  one\n  two\nthree", line: 1, col: 4}
      }
    },
    %{
      name: "dot with no previous change is no-op",
      type: :operator,
      content: "one two",
      cursor: %{line: 0, col: 0},
      keys: ".",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason:
          "Neovim inserts a tab on `.` with no prior change in a fresh buffer; Minga treats it as a no-op.",
        failures: [:content],
        actual: %{content: "one two"}
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
