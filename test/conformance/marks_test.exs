defmodule Minga.Conformance.MarksTest do
  # Conformance tests invoke nvim as an OS process, so they run serially to avoid erl_child_setup EPIPE races.
  use Minga.Test.ConformanceCase, async: false

  @scenarios [
    %{
      name: "tick-a jumps to mark line first non-blank",
      type: :mark,
      content: "  one\n  two\n  three\n  four\n  five",
      cursor: %{line: 2, col: 4},
      commands: ["ma", "gg", "'a"],
      compare: :cursor
    },
    %{
      name: "backtick-a jumps to exact mark position",
      type: :mark,
      content: "  one\n  two\n  three\n  four\n  five",
      cursor: %{line: 2, col: 4},
      commands: ["ma", "gg", "`a"],
      compare: :cursor
    },
    %{
      name: "multiple marks: backtick-a returns to first mark",
      type: :mark,
      content: "one\ntwo\nthree\nfour\nfive",
      cursor: %{line: 1, col: 1},
      commands: ["ma", "3G2l", "mb", "gg", "`a"],
      compare: :cursor
    },
    %{
      name: "multiple marks: backtick-b goes to second mark",
      type: :mark,
      content: "one\ntwo\nthree\nfour\nfive",
      cursor: %{line: 1, col: 1},
      commands: ["ma", "3G2l", "mb", "gg", "`b"],
      compare: :cursor,
      tags: [:known_divergence],
      known_divergence: %{
        reason:
          "Minga's 3G goes to first non-blank (col 0) instead of preserving column. Mark b is set one column earlier, so backtick-b lands at (2, 2) instead of (2, 3).",
        failures: [:cursor],
        actual: %{line: 2, col: 2}
      }
    },
    %{
      name: "jump to unset mark leaves cursor unchanged",
      type: :mark,
      content: "one\ntwo\nthree",
      cursor: %{line: 1, col: 1},
      commands: ["'z"],
      compare: :cursor
    },
    %{
      name: "tick-tick after tick-a returns to pre-jump line",
      type: :mark,
      content: "  one\n  two\n  three\n  four\n  five",
      cursor: %{line: 3, col: 3},
      commands: ["ma", "gg", "'a", "''"],
      compare: :cursor
    },
    %{
      name: "backtick-backtick after backtick-a returns to exact pre-jump position",
      type: :mark,
      content: "one\ntwo\nthree\nfour\nfive",
      cursor: %{line: 3, col: 2},
      commands: ["ma", "gg", "`a", "``"],
      compare: :cursor,
      tags: [:known_divergence],
      known_divergence: %{
        reason:
          "Minga's gg goes to col 0 instead of preserving column, so the backtick-backtick mark records (0, 0) instead of (0, 2).",
        failures: [:cursor],
        actual: %{line: 0, col: 0}
      }
    },
    %{
      name: "mark line shifts down when lines inserted above",
      type: :mark,
      content: "one\ntwo\nthree\nfour\nfive",
      cursor: %{line: 2, col: 2},
      commands: ["ma", "ggOnew line<Esc>", "`a"],
      compare: :cursor,
      tags: [:known_divergence],
      known_divergence: %{
        reason:
          "Minga marks do not adjust line positions when lines are inserted above them. Mark stays at original line 2 instead of shifting to line 3.",
        failures: [:cursor],
        actual: %{line: 2, col: 2}
      }
    },
    %{
      name: "deleting marked line invalidates mark",
      type: :mark,
      content: "one\ntwo\nthree\nfour\nfive",
      cursor: %{line: 2, col: 1},
      commands: ["ma", "dd", "`a"],
      compare: :cursor
    },
    %{
      name: "tick-tick from last line after gg returns to last line",
      type: :mark,
      content: "one\ntwo\nthree\nfour\nfive",
      cursor: %{line: 4, col: 0},
      commands: ["gg", "''"],
      compare: :cursor,
      tags: [:known_divergence],
      known_divergence: %{
        reason:
          "Minga does not set the '' special mark when gg is executed, so '' is a no-op and cursor stays at line 0.",
        failures: [:cursor],
        actual: %{line: 0, col: 0}
      }
    },
    %{
      name: "marks on same line at different columns resolve independently",
      type: :mark,
      content: "hello world test",
      cursor: %{line: 0, col: 2},
      commands: ["ma", "8l", "mb", "0", "`b"],
      compare: :cursor
    },
    %{
      name: "mark col preserved after editing text on marked line",
      type: :mark,
      content: "one\nhello world\nthree",
      cursor: %{line: 1, col: 6},
      commands: ["ma", "0x", "`a"],
      compare: :cursor
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
