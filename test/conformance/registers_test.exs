defmodule Minga.Conformance.RegistersTest do
  # Conformance tests invoke nvim as an OS process, so they run serially to avoid erl_child_setup EPIPE races.
  use Minga.Test.ConformanceCase, async: false

  @compare [:content, :cursor, :mode, :register, :register_type]

  @scenarios [
    %{
      name: "yy populates default register with linewise content",
      type: :register,
      content: "one\ntwo",
      cursor: %{line: 0, col: 0},
      keys: "yy",
      compare: @compare
    },
    %{
      name: "yw populates default register with charwise word",
      type: :register,
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
      name: "named register ayy populates register a",
      type: :register,
      content: "one\ntwo",
      cursor: %{line: 0, col: 0},
      keys: "\"ayy",
      capture_registers: ["a", ""],
      compare: [:content, :cursor, :mode, :registers]
    },
    %{
      name: "black hole register does not populate default register",
      type: :register,
      content: "one\ntwo\nthree",
      cursor: %{line: 0, col: 0},
      keys: "\"_dd",
      compare: [:content, :cursor, :mode, :register]
    },
    %{
      name: "dd then p pastes deleted line below",
      type: :register,
      content: "one\ntwo\nthree",
      cursor: %{line: 0, col: 0},
      keys: "ddp",
      compare: @compare
    },
    %{
      name: "dw then p pastes deleted word after cursor",
      type: :register,
      content: "one two three",
      cursor: %{line: 0, col: 0},
      keys: "dwp",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still deletes and pastes the wrong span for `dw` + `p`.",
        failures: [:content, :cursor, :register],
        actual: %{content: "wone to three", line: 0, col: 6, register: "one t"}
      }
    },
    %{
      name: "uppercase register appends to named register",
      type: :register,
      content: "first\nsecond\nthird",
      cursor: %{line: 0, col: 0},
      keys: "\"ayyj\"Ayy",
      capture_registers: ["a"],
      compare: [:content, :cursor, :mode, :registers]
    },
    %{
      name: "yy overwrites previous default register content",
      type: :register,
      content: "first\nsecond",
      cursor: %{line: 0, col: 0},
      keys: "yyjyy",
      compare: @compare
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
