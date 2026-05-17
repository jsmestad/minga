defmodule Minga.Conformance.MotionsTest do
  # Conformance tests invoke nvim as an OS process, so they run serially to avoid erl_child_setup EPIPE races.
  use Minga.Test.ConformanceCase, async: false

  @scenarios [
    %{
      name: "h moves left within a line",
      type: :motion,
      content: "abcd",
      cursor: %{line: 0, col: 2},
      keys: "h",
      compare: :cursor
    },
    %{
      name: "h stays at start of line",
      type: :motion,
      content: "abcd",
      cursor: %{line: 0, col: 0},
      keys: "h",
      compare: :cursor
    },
    %{
      name: "l moves right within a line",
      type: :motion,
      content: "abcd",
      cursor: %{line: 0, col: 1},
      keys: "l",
      compare: :cursor
    },
    %{
      name: "l stops on last character",
      type: :motion,
      content: "abcd",
      cursor: %{line: 0, col: 3},
      keys: "l",
      compare: :cursor
    },
    %{
      name: "j moves down preserving column",
      type: :motion,
      content: "one\ntwo\nthree",
      cursor: %{line: 0, col: 1},
      keys: "j",
      compare: :cursor
    },
    %{
      name: "j clamps to shorter line",
      type: :motion,
      content: "abcd\nx\nlonger",
      cursor: %{line: 0, col: 3},
      keys: "j",
      compare: :cursor
    },
    %{
      name: "j stays on final line",
      type: :motion,
      content: "one\ntwo",
      cursor: %{line: 1, col: 1},
      keys: "j",
      compare: :cursor
    },
    %{
      name: "k moves up preserving column",
      type: :motion,
      content: "one\ntwo\nthree",
      cursor: %{line: 2, col: 2},
      keys: "k",
      compare: :cursor
    },
    %{
      name: "k clamps to shorter line",
      type: :motion,
      content: "x\nabcd",
      cursor: %{line: 1, col: 3},
      keys: "k",
      compare: :cursor
    },
    %{
      name: "k stays on first line",
      type: :motion,
      content: "one\ntwo",
      cursor: %{line: 0, col: 1},
      keys: "k",
      compare: :cursor
    },
    %{
      name: "w moves to next word",
      type: :motion,
      content: "one two three",
      cursor: %{line: 0, col: 0},
      keys: "w",
      compare: :cursor
    },
    %{
      name: "w skips punctuation",
      type: :motion,
      content: "one, two",
      cursor: %{line: 0, col: 0},
      keys: "w",
      compare: :cursor
    },
    %{
      name: "w crosses line",
      type: :motion,
      content: "one\ntwo",
      cursor: %{line: 0, col: 0},
      keys: "w",
      compare: :cursor
    },
    %{
      name: "b moves to previous word",
      type: :motion,
      content: "one two three",
      cursor: %{line: 0, col: 8},
      keys: "b",
      compare: :cursor
    },
    %{
      name: "b crosses line",
      type: :motion,
      content: "one\ntwo three",
      cursor: %{line: 1, col: 0},
      keys: "b",
      compare: :cursor
    },
    %{
      name: "e moves to end of current word",
      type: :motion,
      content: "one two",
      cursor: %{line: 0, col: 0},
      keys: "e",
      compare: :cursor
    },
    %{
      name: "e moves to end of next word from whitespace",
      type: :motion,
      content: "one two",
      cursor: %{line: 0, col: 3},
      keys: "e",
      compare: :cursor
    },
    %{
      name: "W moves by WORD",
      type: :motion,
      content: "one.two three",
      cursor: %{line: 0, col: 0},
      keys: "W",
      compare: :cursor
    },
    %{
      name: "B moves by WORD",
      type: :motion,
      content: "one.two three",
      cursor: %{line: 0, col: 8},
      keys: "B",
      compare: :cursor
    },
    %{
      name: "E moves to WORD end",
      type: :motion,
      content: "one.two three",
      cursor: %{line: 0, col: 0},
      keys: "E",
      compare: :cursor
    },
    %{
      name: "0 moves to first column",
      type: :motion,
      content: "  one",
      cursor: %{line: 0, col: 4},
      keys: "0",
      compare: :cursor
    },
    %{
      name: "caret moves to first nonblank",
      type: :motion,
      content: "  one",
      cursor: %{line: 0, col: 4},
      keys: "^",
      compare: :cursor
    },
    %{
      name: "dollar moves to final character",
      type: :motion,
      content: "one two",
      cursor: %{line: 0, col: 0},
      keys: "$",
      compare: :cursor
    },
    %{
      name: "gg moves to first line",
      type: :motion,
      content: "one\ntwo\nthree",
      cursor: %{line: 2, col: 1},
      keys: "gg",
      compare: :cursor,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still lands one column earlier than Neovim for `gg`.",
        failures: [:cursor],
        actual: %{line: 0, col: 0}
      }
    },
    %{
      name: "G moves to final line",
      type: :motion,
      content: "one\ntwo\nthree",
      cursor: %{line: 0, col: 1},
      keys: "G",
      compare: :cursor,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still lands one column too far right for `G`.",
        failures: [:cursor],
        actual: %{line: 2, col: 4}
      }
    },
    %{
      name: "f finds next character",
      type: :motion,
      content: "abc def",
      cursor: %{line: 0, col: 0},
      keys: "fd",
      compare: :cursor
    },
    %{
      name: "F finds previous character",
      type: :motion,
      content: "abc def",
      cursor: %{line: 0, col: 6},
      keys: "Fc",
      compare: :cursor
    },
    %{
      name: "t moves before next character",
      type: :motion,
      content: "abc def",
      cursor: %{line: 0, col: 0},
      keys: "td",
      compare: :cursor
    },
    %{
      name: "T moves after previous character",
      type: :motion,
      content: "abc def",
      cursor: %{line: 0, col: 6},
      keys: "Tc",
      compare: :cursor
    },
    %{
      name: "right brace moves to next paragraph",
      type: :motion,
      content: "one\n\ntwo\n\nthree",
      cursor: %{line: 0, col: 0},
      keys: "}",
      compare: :cursor
    },
    %{
      name: "left brace moves to previous paragraph",
      type: :motion,
      content: "one\n\ntwo\n\nthree",
      cursor: %{line: 4, col: 0},
      keys: "{",
      compare: :cursor
    },
    %{
      name: "percent matches parentheses",
      type: :motion,
      content: "call(arg)",
      cursor: %{line: 0, col: 4},
      keys: "%",
      compare: :cursor,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still matches the opening parenthesis instead of the closing match.",
        failures: [:cursor],
        actual: %{line: 0, col: 4}
      }
    },
    %{
      name: "percent matches brackets",
      type: :motion,
      content: "list[0]",
      cursor: %{line: 0, col: 4},
      keys: "%",
      compare: :cursor,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still matches the opening bracket instead of the closing match.",
        failures: [:cursor],
        actual: %{line: 0, col: 4}
      }
    },
    %{
      name: "percent matches braces",
      type: :motion,
      content: "map{key}",
      cursor: %{line: 0, col: 3},
      keys: "%",
      compare: :cursor,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still matches the opening brace instead of the closing match.",
        failures: [:cursor],
        actual: %{line: 0, col: 3}
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
