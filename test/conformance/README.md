# Vim conformance tests

These tests compare Minga's vim grammar against vanilla Neovim. The current suite starts with deterministic text-editing behavior for motions, operators, text objects, counts, registers, and content/cursor comparisons. Search and visual-mode behavior can be added as coverage grows. Doom-style UI behavior belongs in normal Minga integration tests, not here.

Each scenario is plain Elixir data in `*_test.exs`:

```elixir
%{
  name: "dw deletes word",
  type: :operator,
  content: "one two",
  cursor: %{line: 0, col: 0},
  keys: "dw",
  compare: [:content, :cursor, :mode, :register, :register_type],
  tags: [:known_divergence],
  known_divergence: %{
    reason: "Minga still deletes the wrong span and yanks the wrong unnamed register for word-delete motions.",
    failures: [:content, :register],
    actual: %{content: "wo", register: "one t"}
  }
}
```

The scenario fields are:

- `:name`, a unique test name.
- `:type`, one of `:motion`, `:operator`, or `:text_object`.
- `:content`, the initial buffer text.
- `:cursor`, a zero-indexed `%{line:, col:}` position. Neovim uses one-indexed lines internally, but the oracle converts back to Minga's zero-indexed coordinates.
- `:keys`, the normal-mode key sequence sent to both editors.
- `:compare`, one of `:content`, `:cursor`, `:mode`, `:register`, `:register_type`, `:both`, or a list of any of those fields.
- `:tags`, optional. Use `[:known_divergence]` for scenarios where Minga currently differs from Neovim in a tracked and expected way.
- `:known_divergence`, optional. When present, it must include a scenario-specific `:reason`, the exact `:failures` list, and an `:actual` map for the current Minga fields that differ.

`test/conformance/oracle.lua` reads the JSON scenario file emitted by `Minga.Test.NeovimOracle`, creates a fresh Neovim buffer for each scenario, feeds the key sequence through Neovim after termcode replacement, and prints one JSON result per scenario. Adding a scenario should not require changing the Lua script or the Elixir harness.

Known divergences still execute both editors. They pass only while Minga currently differs from Neovim in the exact way described by the scenario data; if a tagged scenario starts matching Neovim, the test fails so the stale tag and divergence data can be removed. Set `MINGA_CONFORMANCE_LOG_DIVERGENCES=1` when you want passing known-divergence tests to print their expected and actual states.

Run only this suite with:

```bash
mix conformance
```

If `nvim` is not on `PATH`, the conformance test modules are skipped with a descriptive message. CI installs the pinned Neovim release listed in `.github/workflows/ci.yml` (currently v0.12.2) before running `mix conformance`; check `nvim --version` locally if a conformance result disagrees with CI.
