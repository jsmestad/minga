defmodule Minga.Conformance.TextObjectsTest do
  # Conformance tests invoke nvim as an OS process, so they run serially to avoid erl_child_setup EPIPE races.
  use Minga.Test.ConformanceCase, async: false

  @compare [:content, :cursor, :mode, :register, :register_type]

  @scenarios [
    %{
      name: "diw deletes inner word",
      type: :text_object,
      content: "one two",
      cursor: %{line: 0, col: 1},
      keys: "diw",
      compare: @compare
    },
    %{
      name: "daw deletes a word",
      type: :text_object,
      content: "one two",
      cursor: %{line: 0, col: 1},
      keys: "daw",
      compare: @compare
    },
    %{
      name: "daw on whitespace deletes surrounding word text",
      type: :text_object,
      content: "one two",
      cursor: %{line: 0, col: 3},
      keys: "daw",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still deletes the wrong span when `daw` starts on whitespace.",
        failures: [:content, :cursor, :register],
        actual: %{
          line: 0,
          content: "onetwo",
          col: 3,
          mode: "n",
          register: " ",
          register_type: "v"
        }
      }
    },
    %{
      name: "di double quote deletes inside quotes",
      type: :text_object,
      content: "say \"hello\" now",
      cursor: %{line: 0, col: 6},
      keys: "di\"",
      compare: @compare
    },
    %{
      name: "da double quote deletes around quotes",
      type: :text_object,
      content: "say \"hello\" now",
      cursor: %{line: 0, col: 6},
      keys: "da\"",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still leaves a doubled space after `da\"`.",
        failures: [:content, :register],
        actual: %{
          line: 0,
          content: "say  now",
          mode: "n",
          register: "\"hello\"",
          register_type: "v"
        }
      }
    },
    %{
      name: "di single quote deletes inside quotes",
      type: :text_object,
      content: "say 'hello' now",
      cursor: %{line: 0, col: 6},
      keys: "di'",
      compare: @compare
    },
    %{
      name: "da single quote deletes around quotes",
      type: :text_object,
      content: "say 'hello' now",
      cursor: %{line: 0, col: 6},
      keys: "da'",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still leaves a doubled space after `da'`.",
        failures: [:content, :register],
        actual: %{
          line: 0,
          content: "say  now",
          mode: "n",
          register: "'hello'",
          register_type: "v"
        }
      }
    },
    %{
      name: "di paren deletes inside parentheses",
      type: :text_object,
      content: "call(one, two)",
      cursor: %{line: 0, col: 6},
      keys: "di(",
      compare: @compare
    },
    %{
      name: "da paren deletes around parentheses",
      type: :text_object,
      content: "call(one, two)",
      cursor: %{line: 0, col: 6},
      keys: "da(",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still lands one column too far right for `da(`.",
        failures: [:cursor],
        actual: %{line: 0, col: 4, mode: "n", register: "(one, two)", register_type: "v"}
      }
    },
    %{
      name: "di brace deletes inside braces",
      type: :text_object,
      content: "map{one: two}",
      cursor: %{line: 0, col: 5},
      keys: "di{",
      compare: @compare
    },
    %{
      name: "da brace deletes around braces",
      type: :text_object,
      content: "map{one: two}",
      cursor: %{line: 0, col: 5},
      keys: "da{",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still lands one column too far right for `da{`.",
        failures: [:cursor],
        actual: %{line: 0, col: 3, mode: "n", register: "{one: two}", register_type: "v"}
      }
    },
    %{
      name: "di bracket deletes inside brackets",
      type: :text_object,
      content: "list[one, two]",
      cursor: %{line: 0, col: 6},
      keys: "di[",
      compare: @compare
    },
    %{
      name: "da bracket deletes around brackets",
      type: :text_object,
      content: "list[one, two]",
      cursor: %{line: 0, col: 6},
      keys: "da[",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still lands one column too far right for `da[`.",
        failures: [:cursor],
        actual: %{line: 0, col: 4, mode: "n", register: "[one, two]", register_type: "v"}
      }
    },
    %{
      name: "di paren handles empty pair",
      type: :text_object,
      content: "call()",
      cursor: %{line: 0, col: 4},
      keys: "di(",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still lands one column too early for `di(` on an empty pair.",
        failures: [:cursor],
        actual: %{line: 0, col: 4, mode: "n", register: "", register_type: "v"}
      }
    },
    %{
      name: "di paren handles nested pair",
      type: :text_object,
      content: "outer(inner(value))",
      cursor: %{line: 0, col: 12},
      keys: "di(",
      compare: @compare
    },
    %{
      name: "da paren from delimiter deletes pair",
      type: :text_object,
      content: "call(one)",
      cursor: %{line: 0, col: 4},
      keys: "da(",
      compare: @compare,
      tags: [:known_divergence],
      known_divergence: %{
        reason: "Minga still leaves the original delimiter text behind for `da(`.",
        failures: [:content, :cursor, :register],
        actual: %{
          line: 0,
          content: "call(one)",
          col: 4,
          mode: "n",
          register: "",
          register_type: "v"
        }
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
