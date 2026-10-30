# Changelog

All notable changes to Minga are documented here. This file is automatically updated by the release pipeline when a new version is published.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## Unreleased

### Changed

- Native agents now use the upstream ReqLLM 1.29 release instead of a pinned fork, bringing Codex reasoning-continuation fixes, preserved streamed JSON text and thinking, and transport security fixes. Updated compatible Hex dependencies, including Req 0.7.5, Bandit 1.14.1, Exqlite 0.43.0, Hammox 1.0, and the October LLM model catalog.
- Agent guides now use verified paths and module entry points, list all fourteen custom Credo checks with unique IDs, and link focused development recipes. Regression tests keep guide references and the check inventory synchronized with the repository.
- Production parser and hook-runner binaries now use Zig `ReleaseSafe`, with Zig's build cache selecting the correct optimization mode. Parser queries compile only for languages in use instead of prewarming every bundled language. Editor launchers retain ERTS's specialized memory allocators instead of disabling them.
- Removed one-off benchmark scripts and archived measurement artifacts. CI performance gates and maintained documentation remain.
- LSP, diagnostic, and caret position conversion now walks UTF-8 text directly instead of building charlists or re-encoding each character, and UTF-32 position lookup runs in constant stack. Converted positions, clamping, and exact-column errors are unchanged.
- GUI search indexes now build in one linear pass when indexing into an empty tree, so initial builds and edits that remove every match no longer insert each match-bearing line persistently. Match order, counts, navigation, and incremental edits are unchanged.
- Characterwise range deletion and replacement reuse their already resolved selections, avoiding a second normalization and coordinate lookup while preserving deleted and replacement bytes, cursor placement, and edit deltas.
- Window source maps for unchanged, undecorated lines without expanded tabs now skip the composition pipeline and count UTF-16 once. Decorated lines measure source display width at most once and query conceals and inline virtual text once.
- Diagnostic decoration updates group consecutive endpoint-line reads, convert positions outside the buffer process, and share severity styles. Highlight ranges, ordering, unrelated decoration groups, and the existing read/install behavior are preserved.
- LSP change flushes share the first successful full-content snapshot across full-sync clients instead of flattening the document once per client. UTF-8 incremental clients with available deltas keep their range-only path, and failed reads still retry for later clients.
- macOS editor command preparation reuses unscrolled rows that fit the viewport instead of rebuilding their text and highlight spans. Clipped, scrolled, and out-of-range-span rows keep the existing normalization.
- macOS selection overlays index accessibility ranges once per pane and frame instead of rescanning every range for each visible row. Selection quad geometry, ordering, clipping and colors are unchanged.
- Full-content undo commits now find the changed byte range with native binary prefix and suffix comparison over bounded 4 KiB chunks instead of a per-byte Elixir scan, without copying either whole document. Patch contents, apply/invert behavior, and cursor restoration are unchanged.
- Opening or reloading a buffer in which no line starts with a merge conflict marker no longer splits every line or copies the document to build the conflict index. On a 60,000-line, 3.9 MB ASCII document, building the index drops from about 8 ms to 0.3 ms (median) wherever the edit gap sits. Documents with any marker line, including orphan markers, are indexed as before.
- Placing the cursor, including vertical moves and jumps, no longer flushes a pending line-index shift or copies the target line separately from the document. The caret clamp reads only through the requested code point, and placement uses at most one content copy. Controlled 60,000-line probes measured one-line moves with a pending shift at about 0.5–0.7 ms before and under 0.1 ms after (median), with no increase in retained binary memory. Clean regular-line and long-single-line controls remained within measurement variation. Line and column clamping, grapheme boundaries, CRLF handling, and index contents are unchanged. Clearing an already-empty line at the cursor after an edit round-trip is now a no-op even with a pending index, rather than recording a zero-width edit.
- Buffer file opens, byte-range replacements, and undo reconstruction now validate UTF-8 through the VM's native Unicode converter instead of `String.valid?/1`. Accepted and rejected input is unchanged; validating multi-megabyte files is roughly four to five times faster.
- Empty LSP semantic-token responses now check only the buffer revision instead of copying, splitting, and indexing the whole document before storing an empty layer. On 60,000-line documents of 3.5 to 7.8 MB, accepting an empty response drops from about 17 ms to under 20 µs (median), and caller heap allocation drops from about 4.5 million words to 81. Cleared layers, stale or closed-buffer rejection, and non-empty responses are unchanged.
- Case-sensitive regex searches and substitutions whose pattern contains no regex metacharacters now use the literal byte matcher instead of compiling a regex. Matches, overlaps, replacements, and invalid-regex fallback are unchanged.
- Ordinary editor startup defers agent model discovery until agent use and starts the bundled BEAM before native font and Metal setup. Unresolved models retain truthful readiness, and exact hosted route startup preserves the selected reasoning policy.
- Agent model selection now supports named hosted providers only. Ollama, anonymous routes, custom endpoints, endpoint overrides, local availability probes, and their configuration options have been removed. Unsupported routes fail without provider fallback or network probing.
- Agent tool advice now carries tool results through an explicit tagged invocation outcome. Tool-specific around callbacks must return `{:returned, state, result}` or `{:skipped, state}`; editor command advice keeps its existing state-to-state contract.
- Native agent tool effects now require a durable provider-continuation checkpoint and single-attempt admission; interrupted admitted calls recover as explicit indeterminate results without replay.
- Native agent model changes now resolve an exact model, wire protocol, endpoint, credential profile, reasoning controls, limits, and capabilities before activation. The model picker and slash completion expose exact route evidence; unsupported tool, image, and thinking requests are rejected before transport; and saved sessions restore the same secret-free route identity without credential fallback. See `docs/AGENT-MODEL-SELECTION.md`.
- Native agent reads, discovery, searches, shell results, and tool results now distinguish visible truncation from bounded durable capture, support binary-safe exact record-scoped retrieval across restart, preserve source revisions and timeout prefixes, reconcile interrupted delivery outputs without replay, and explicitly refuse retention quota failures. Image reads deliver retained bytes through exact model and protocol support or return a visible limitation before full capture. Combined snapshots preserve output ownership and migrate separate model-selection and retained-output records safely.

### Fixed

- Repeated release builds no longer accumulate obsolete Erlang runtimes and dependency versions. macOS and standalone TUI packages include only Minga's runtime resources, excluding test harnesses, retired renderers, and other development leftovers. Production Go renderers omit debug metadata and local build paths without removing language support or runtime extension compilation.
- Release cleanup refuses output paths outside the active Mix build directory, protecting shared installation prefixes from deletion. Custom `mix release --path` destinations must be below that build directory.
- Cursor-left and Backspace no longer scan all preceding buffer text on each action. Line-boundary lookup searches backward in bounded chunks, and grapheme lookup reads only the final line while preserving Unicode and CRLF boundaries.
- Converting between document points and editor positions no longer walks or copies buffer content. Range edits, replacements, and edit deltas resolve positions through the cached line index, including pending line shifts, while keeping exact byte columns.
- Deleting or moving the cursor across a CRLF line ending now updates the line count, cursor line, and line index. Previously the CRLF pair was treated as an ordinary character, so later positions resolved to the wrong line.
- Git tracking resolves project-directory aliases before reading HEAD, including new paths under a symlinked parent.
- Whole-file additions and deletions use direct line-diff hunks instead of a quadratic Myers workspace, preventing large transient heaps for untracked files.
- The macOS protocol reader releases temporary Foundation read buffers after each packet instead of retaining them until its background thread exits.
- Extension callback completions reuse the request snapshot when no state changed, and the effect scheduler releases its idle heap after a burst.
- Bundled extensions boot their isolated compiler and validator with the release's clean boot script and library path.
- Bounded agent command collection now terminates live producers before closing their Ports on timeout or capture exhaustion. Search and shell commands no longer continue consuming CPU after returning an incomplete result.

<!-- RELEASE_MARKER: new releases are prepended above this line -->
