defmodule Minga.Conformance.WindowsTest do
  @moduledoc false
  # Conformance tests invoke nvim as an OS process, so they run serially to avoid erl_child_setup EPIPE races.
  use Minga.Test.ConformanceCase, async: false

  @scenarios [
    # ── Vertical split ──────────────────────────────────────────────────────
    %{
      name: "vsplit creates two windows with same buffer",
      type: :window,
      content: "hello world",
      cursor: %{line: 0, col: 0},
      commands: ["vsplit"],
      minga_keys: ["<Space>wv"],
      compare: :window_state
    },

    # ── Horizontal split ────────────────────────────────────────────────────
    %{
      name: "split creates two windows with same buffer",
      type: :window,
      content: "hello world",
      cursor: %{line: 0, col: 0},
      commands: ["split"],
      minga_keys: ["<Space>ws"],
      compare: :window_state
    },

    # ── Nested split (3 windows) ────────────────────────────────────────────
    %{
      name: "vsplit then split in one pane creates three windows",
      type: :window,
      content: "three panes",
      cursor: %{line: 0, col: 0},
      commands: ["vsplit", "split"],
      minga_keys: ["<Space>wv", "<Space>ws"],
      compare: [:window_count]
    },

    # ── Navigation: wincmd h ────────────────────────────────────────────────
    %{
      name: "wincmd h from right window activates left window",
      type: :window,
      content: "navigate left",
      cursor: %{line: 0, col: 0},
      commands: ["vsplit", "wincmd l", "wincmd h"],
      minga_keys: ["<Space>wv", "<Space>wl", "<Space>wh"],
      compare: [:window_count, :active_window]
    },

    # ── Navigation: wincmd l ────────────────────────────────────────────────
    %{
      name: "wincmd l from left window activates right window",
      type: :window,
      content: "navigate right",
      cursor: %{line: 0, col: 0},
      commands: ["vsplit", "wincmd l"],
      minga_keys: ["<Space>wv", "<Space>wl"],
      compare: [:window_count, :active_window]
    },

    # ── Navigation: wincmd j ────────────────────────────────────────────────
    %{
      name: "wincmd j moves focus down in horizontal split",
      type: :window,
      content: "navigate down",
      cursor: %{line: 0, col: 0},
      commands: ["split", "wincmd j"],
      minga_keys: ["<Space>ws", "<Space>wj"],
      compare: [:window_count, :active_window]
    },

    # ── Navigation: wincmd k ────────────────────────────────────────────────
    %{
      name: "wincmd k moves focus up in horizontal split",
      type: :window,
      content: "navigate up",
      cursor: %{line: 0, col: 0},
      commands: ["split", "wincmd j", "wincmd k"],
      minga_keys: ["<Space>ws", "<Space>wj", "<Space>wk"],
      compare: [:window_count, :active_window]
    },

    # ── Navigation wrapping: rightmost wincmd l is no-op ────────────────────
    %{
      name: "wincmd l when already rightmost is no-op",
      type: :window,
      content: "no wrap right",
      cursor: %{line: 0, col: 0},
      commands: ["vsplit", "wincmd l", "wincmd l"],
      minga_keys: ["<Space>wv", "<Space>wl", "<Space>wl"],
      compare: [:window_count, :active_window]
    },

    # ── Close non-last window ───────────────────────────────────────────────
    %{
      name: "close non-last window reduces count by one",
      type: :window,
      content: "close test",
      cursor: %{line: 0, col: 0},
      commands: ["vsplit", "close"],
      minga_keys: ["<Space>wv", "<Space>wd"],
      compare: [:window_count, :active_window]
    },

    # ── Last window protection ──────────────────────────────────────────────
    %{
      name: "close last window is rejected",
      type: :window,
      content: "last window",
      cursor: %{line: 0, col: 0},
      commands: ["close"],
      minga_keys: ["<Space>wd"],
      compare: [:window_count, :active_window]
    },

    # ── Cursor position independent per window ──────────────────────────────
    %{
      name: "cursor position is independent per window",
      type: :window,
      content: "abcdefgh\nline two",
      cursor: %{line: 0, col: 0},
      commands: ["vsplit", "normal! 4l", "wincmd l"],
      minga_keys: ["<Space>wv", "4l", "<Space>wl"],
      compare: [:window_count, :cursors]
    },

    # ── Split then close returns to single window ───────────────────────────
    %{
      name: "split then close returns to single window",
      type: :window,
      content: "restore single",
      cursor: %{line: 0, col: 0},
      commands: ["vsplit", "close"],
      minga_keys: ["<Space>wv", "<Space>wd"],
      compare: [:window_count]
    },

    # ── Three-way split: close one ──────────────────────────────────────────
    %{
      name: "three-way split close reduces to two windows",
      type: :window,
      content: "three way",
      cursor: %{line: 0, col: 0},
      commands: ["vsplit", "vsplit", "close"],
      minga_keys: ["<Space>wv", "<Space>wv", "<Space>wd"],
      compare: [:window_count]
    },

    # ── Navigation wrapping: leftmost wincmd h is no-op ─────────────────────
    %{
      name: "wincmd h when already leftmost is no-op",
      type: :window,
      content: "no wrap left",
      cursor: %{line: 0, col: 0},
      commands: ["vsplit", "wincmd h", "wincmd h"],
      minga_keys: ["<Space>wv", "<Space>wh", "<Space>wh"],
      compare: [:window_count, :active_window]
    },

    # ── Multiple splits and cursor independence ──────────────────────────────
    %{
      name: "edit in one window does not change other window cursor",
      type: :window,
      content: "original text\nsecond line",
      cursor: %{line: 0, col: 0},
      commands: ["vsplit", "normal! j$", "wincmd l"],
      minga_keys: ["<Space>wv", "j$", "<Space>wl"],
      compare: [:window_count, :cursors]
    },

    # ── Different buffers in different windows ──────────────────────────────
    %{
      name: "different buffers in split windows are independent",
      type: :window,
      content: "original content",
      cursor: %{line: 0, col: 0},
      commands: ["vsplit", "enew"],
      minga_keys: ["<Space>wv", ":enew<CR>"],
      compare: [:window_count, :buffers]
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
      assert_window_conforms(unquote(Macro.escape(scenario)), oracle_results)
    end
  end
end
