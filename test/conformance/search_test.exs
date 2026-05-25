defmodule Minga.Conformance.SearchTest do
  # Conformance tests invoke nvim as an OS process, so they run serially to avoid erl_child_setup EPIPE races.
  use Minga.Test.ConformanceCase, async: false

  @scenarios [
    # ── / forward search ──────────────────────────────────────────────────────

    %{
      name: "/word finds first occurrence forward",
      type: :search,
      content: "hello world hello",
      cursor: %{line: 0, col: 0},
      keys: "/hello<CR>",
      compare: :cursor
    },
    %{
      name: "/word from middle finds next occurrence, not previous",
      type: :search,
      content: "hello world hello again",
      cursor: %{line: 0, col: 6},
      keys: "/hello<CR>",
      compare: :cursor
    },

    # ── ? backward search ─────────────────────────────────────────────────────

    %{
      name: "?word finds first occurrence backward",
      type: :search,
      content: "hello world hello",
      cursor: %{line: 0, col: 16},
      keys: "?hello<CR>",
      compare: :cursor
    },

    # ── n after / ─────────────────────────────────────────────────────────────

    %{
      name: "n after /word advances to next match",
      type: :search,
      content: "foo bar foo baz foo",
      cursor: %{line: 0, col: 0},
      keys: "/foo<CR>n",
      compare: :cursor
    },

    # ── N after / ─────────────────────────────────────────────────────────────

    %{
      name: "N after /word goes to previous match",
      type: :search,
      content: "foo bar foo baz foo",
      cursor: %{line: 0, col: 4},
      keys: "/foo<CR>N",
      compare: :cursor
    },

    # ── n after ? ─────────────────────────────────────────────────────────────

    %{
      name: "n after ?word goes backward (same direction as ?)",
      type: :search,
      content: "foo bar foo baz foo",
      cursor: %{line: 0, col: 18},
      keys: "?foo<CR>n",
      compare: :cursor
    },

    # ── wrap past EOF ─────────────────────────────────────────────────────────

    %{
      name: "search wraps past end-of-file",
      type: :search,
      content: "alpha\nbeta\nalpha",
      cursor: %{line: 2, col: 0},
      keys: "/alpha<CR>",
      compare: :cursor
    },

    # ── wrap past BOF ─────────────────────────────────────────────────────────

    %{
      name: "search wraps past beginning-of-file",
      type: :search,
      content: "alpha\nbeta\nalpha",
      cursor: %{line: 0, col: 0},
      keys: "?alpha<CR>",
      compare: :cursor
    },

    # ── * word under cursor forward ───────────────────────────────────────────

    %{
      name: "* searches forward for word under cursor",
      type: :search,
      content: "one two one three one",
      cursor: %{line: 0, col: 0},
      keys: "*",
      compare: :cursor
    },
    %{
      name: "* sets search register so n advances to next match",
      type: :search,
      content: "one two one three one",
      cursor: %{line: 0, col: 0},
      keys: "*n",
      compare: :cursor
    },

    # ── # word under cursor backward ──────────────────────────────────────────

    %{
      name: "# searches backward for word under cursor",
      type: :search,
      content: "one two one three one",
      cursor: %{line: 0, col: 18},
      keys: "#",
      compare: :cursor
    },

    # ── no match ──────────────────────────────────────────────────────────────

    %{
      name: "search with no match leaves cursor unchanged",
      type: :search,
      content: "hello world",
      cursor: %{line: 0, col: 3},
      keys: "/zzzzz<CR>",
      compare: [:cursor, :mode]
    },

    # ── multiple matches on same line ─────────────────────────────────────────

    %{
      name: "/ lands on first match past cursor on same line",
      type: :search,
      content: "aa bb aa bb aa",
      cursor: %{line: 0, col: 1},
      keys: "/aa<CR>",
      compare: :cursor
    },

    # ── search across line boundaries ─────────────────────────────────────────

    %{
      name: "n after / crosses line boundaries",
      type: :search,
      content: "one two\nthree one\nfour one",
      cursor: %{line: 0, col: 0},
      keys: "/one<CR>n",
      compare: :cursor
    },

    # ── search from middle of file ────────────────────────────────────────────

    %{
      name: "/ from middle of file finds match on later line",
      type: :search,
      content: "aaa\nbbb\nccc\naaa",
      cursor: %{line: 1, col: 0},
      keys: "/aaa<CR>",
      compare: :cursor
    },

    # ── pattern with special characters ───────────────────────────────────────

    %{
      name: "/ with literal dot finds dot character",
      type: :search,
      content: "foo.bar baz",
      cursor: %{line: 0, col: 0},
      keys: "/\\.<CR>",
      compare: :cursor,
      tags: [:known_divergence],
      known_divergence: %{
        reason:
          "Neovim interprets /-search patterns as vim magic-mode regex where \\. matches a literal dot. Minga performs plain substring search for slash-search input, so the literal two characters \\. do not match the dot in foo.bar.",
        failures: [:cursor],
        actual: %{line: 0, col: 0}
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
