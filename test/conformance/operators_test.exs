defmodule Minga.Conformance.OperatorsTest do
  # Conformance tests invoke nvim as an OS process, so they run serially to avoid erl_child_setup EPIPE races.
  use Minga.Test.ConformanceCase, async: false

  @compare [:content, :cursor, :mode, :register, :register_type]

  @scenarios [
    %{
      name: "dw deletes word",
      type: :operator,
      content: "one two",
      cursor: %{line: 0, col: 0},
      keys: "dw",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still deletes one trailing character too many for `dw`.",
        failures: [:content, :register],
        actual: %{content: "wo", register: "one t"}
      }
    },
    %{
      name: "dw deletes across punctuation",
      type: :operator,
      content: "one, two",
      cursor: %{line: 0, col: 0},
      keys: "dw",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason:
          "Minga still deletes one trailing character too many when `dw` crosses punctuation.",
        failures: [:content, :register],
        actual: %{content: " two", register: "one,"}
      }
    },
    %{
      name: "2dw deletes two words",
      type: :operator,
      content: "one two three",
      cursor: %{line: 0, col: 0},
      keys: "2dw",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still deletes one trailing character too many for repeated word deletes.",
        failures: [:content, :register],
        actual: %{content: "hree", register: "wo t"}
      }
    },
    %{
      name: "dd deletes current line",
      type: :operator,
      content: "one\ntwo\nthree",
      cursor: %{line: 1, col: 0},
      keys: "dd",
      compare: @compare
    },
    %{
      name: "3dd deletes three lines",
      type: :operator,
      content: "one\ntwo\nthree\nfour",
      cursor: %{line: 0, col: 0},
      keys: "3dd",
      compare: @compare
    },
    %{
      name: "dollar delete removes to end of line",
      type: :operator,
      content: "one two",
      cursor: %{line: 0, col: 4},
      keys: "d$",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still leaves the cursor one column too far right after `d$`.",
        failures: [:cursor],
        actual: %{line: 0, col: 4}
      }
    },
    %{
      name: "D deletes to end of line",
      type: :operator,
      content: "one two",
      cursor: %{line: 0, col: 4},
      keys: "D",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still leaves the cursor one column too far right after `D`.",
        failures: [:cursor],
        actual: %{line: 0, col: 4}
      }
    },
    %{
      name: "x deletes character under cursor",
      type: :operator,
      content: "one",
      cursor: %{line: 0, col: 1},
      keys: "x",
      compare: @compare
    },
    %{
      name: "X deletes character before cursor",
      type: :operator,
      content: "one",
      cursor: %{line: 0, col: 2},
      keys: "X",
      compare: @compare
    },
    %{
      name: "yw yanks word without changing content",
      type: :operator,
      content: "one two",
      cursor: %{line: 0, col: 0},
      keys: "yw",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still yanks the wrong trailing span for `yw`.",
        failures: [:register],
        actual: %{register: "one t"}
      }
    },
    %{
      name: "yy yanks line without changing content",
      type: :operator,
      content: "one\ntwo",
      cursor: %{line: 0, col: 0},
      keys: "yy",
      compare: @compare
    },
    %{
      name: "p pastes after deleted word",
      type: :operator,
      content: "one two",
      cursor: %{line: 0, col: 0},
      keys: "dwp",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still pastes a deleted word back into the wrong span and cursor position.",
        failures: [:content, :cursor, :register],
        actual: %{line: 0, content: "wone to", col: 6, register: "one t"}
      }
    },
    %{
      name: "P pastes before deleted word",
      type: :operator,
      content: "one two",
      cursor: %{line: 0, col: 0},
      keys: "dwP",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still puts the paste cursor one column too far right after `dwP`.",
        failures: [:cursor, :register],
        actual: %{line: 0, col: 5, register: "one t"}
      }
    },
    %{
      name: "cw changes word",
      type: :operator,
      content: "one two",
      cursor: %{line: 0, col: 0},
      keys: "cw",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still deletes and records the wrong span for `cw`.",
        failures: [:content, :register],
        actual: %{content: "wo", register: "one t"}
      }
    },
    %{
      name: "cc changes current line",
      type: :operator,
      content: "one\ntwo",
      cursor: %{line: 0, col: 0},
      keys: "cc",
      compare: @compare
    },
    %{
      name: "C changes to end of line",
      type: :operator,
      content: "one two",
      cursor: %{line: 0, col: 4},
      keys: "C",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still leaves `C` one column too far right.",
        failures: [:cursor],
        actual: %{line: 0, col: 4}
      }
    },
    %{
      name: "right shift indents line",
      type: :operator,
      content: "one\ntwo",
      cursor: %{line: 0, col: 0},
      keys: ">>",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still indents with spaces and leaves the cursor shifted right for `>>`.",
        failures: [:content, :cursor],
        actual: %{line: 0, col: 2, content: "  one\ntwo"}
      }
    },
    %{
      name: "left shift dedents line",
      type: :operator,
      content: "  one\ntwo",
      cursor: %{line: 0, col: 0},
      keys: "<<",
      compare: @compare
    },
    %{
      name: "dG deletes through final line",
      type: :operator,
      content: "one\ntwo\nthree",
      cursor: %{line: 1, col: 0},
      keys: "dG",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason:
          "Minga still deletes through the end of the file with the wrong span and cursor placement.",
        failures: [:content, :cursor, :register, :register_type],
        actual: %{content: "one\n", line: 1, col: 0, register: "two\nthree", register_type: "v"}
      }
    },
    %{
      name: "dgg deletes through first line",
      type: :operator,
      content: "one\ntwo\nthree",
      cursor: %{line: 2, col: 0},
      keys: "dgg",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still over-deletes when jumping to the top of the file.",
        failures: [:content, :register, :register_type],
        actual: %{content: "hree", register: "one\ntwo\nt", register_type: "v"}
      }
    },
    %{
      name: "d0 deletes to first column",
      type: :operator,
      content: "one two",
      cursor: %{line: 0, col: 4},
      keys: "d0",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still deletes to column 0 with the wrong span.",
        failures: [:content, :register],
        actual: %{content: "wo", register: "one t"}
      }
    },
    %{
      name: "d caret deletes to first nonblank",
      type: :operator,
      content: "  one two",
      cursor: %{line: 0, col: 6},
      keys: "d^",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still deletes to first nonblank with the wrong span.",
        failures: [:content, :register],
        actual: %{content: "  wo", register: "one t"}
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
