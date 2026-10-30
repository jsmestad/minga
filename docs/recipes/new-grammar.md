# Add a tree-sitter grammar

Compile a grammar into the parser so every frontend gets the same syntax analysis. Start with the grammar source and a query that matches that exact grammar version.

1. Vendor the grammar's `src/` directory under `zig/vendor/grammars/`, in a directory named for the language. Include `parser.c` and `scanner.c` when required. Add a `VERSION` file with the upstream git tag or commit hash.
2. Add `highlights.scm` under the language's directory in `zig/src/queries/`. Start with the upstream query and use Minga's supported captures: `keyword`, `string`, `comment`, `function`, `type`, `number`, `operator`, `punctuation`, `variable`, `constant`, `property`, `tag`, `attribute`, `namespace`, `label`, and `special`.
3. Add a `Grammar` entry to the `grammars` array in `zig/build.zig`. Set `has_scanner: true` when the grammar has `scanner.c`.
4. Add the `extern fn tree_sitter_<language>()` declaration and a `builtin_grammars` entry in `zig/src/highlighter.zig`, with the grammar function and `@embedFile` for the query.
5. For a new filetype, add extension and filename mappings in `lib/minga/language/filetype.ex` so the BEAM sends the correct language name. Follow the existing language definitions under `lib/minga/language/`.

From the repository root, generate the parser's shared inputs, compile every shipped query against its grammar, and verify filetype detection:

```bash
mix protocol.gen
mix language_aliases.gen
(cd zig && zig build query-check)
mix test.debug test/minga/language/filetype_test.exs
mix zig.lint
```

The query compilation tests also run under `zig build test`. See the [parser guide](../../zig/AGENTS.md) for parser conventions and query overrides.
