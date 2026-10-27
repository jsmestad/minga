# Changelog

All notable changes to Minga are documented here. This file is automatically updated by the release pipeline when a new version is published.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## Unreleased

### Changed

- Removed one-off benchmark scripts and archived measurement artifacts. CI performance gates and maintained documentation remain.
- LSP, diagnostic, and caret position conversion now walks UTF-8 text directly instead of building charlists or re-encoding each character, and UTF-32 position lookup runs in constant stack. Converted positions, clamping, and exact-column errors are unchanged.
- Full-content undo commits now find the changed byte range with native binary prefix and suffix comparison over bounded 4 KiB chunks instead of a per-byte Elixir scan, without copying either whole document. Patch contents, apply/invert behavior, and cursor restoration are unchanged.
- Opening or reloading a buffer in which no line starts with a merge conflict marker no longer splits every line or copies the document to build the conflict index. On a 60,000-line, 3.9 MB ASCII document, building the index drops from about 8 ms to 0.3 ms (median) wherever the edit gap sits. Documents with any marker line, including orphan markers, are indexed as before.
- Buffer file opens, byte-range replacements, and undo reconstruction now validate UTF-8 through the VM's native Unicode converter instead of `String.valid?/1`. Accepted and rejected input is unchanged; validating multi-megabyte files is roughly four to five times faster.
- Ordinary editor startup defers agent model discovery until agent use and starts the bundled BEAM before native font and Metal setup. Unresolved models retain truthful readiness, and exact hosted route startup preserves the selected reasoning policy.
- Agent model selection now supports named hosted providers only. Ollama, anonymous routes, custom endpoints, endpoint overrides, local availability probes, and their configuration options have been removed. Unsupported routes fail without provider fallback or network probing.
- Agent tool advice now carries tool results through an explicit tagged invocation outcome. Tool-specific around callbacks must return `{:returned, state, result}` or `{:skipped, state}`; editor command advice keeps its existing state-to-state contract.
- Native agent tool effects now require a durable provider-continuation checkpoint and single-attempt admission; interrupted admitted calls recover as explicit indeterminate results without replay.
- Native agent model changes now resolve an exact model, wire protocol, endpoint, credential profile, reasoning controls, limits, and capabilities before activation. The model picker and slash completion expose exact route evidence; unsupported tool, image, and thinking requests are rejected before transport; and saved sessions restore the same secret-free route identity without credential fallback. See `docs/AGENT-MODEL-SELECTION.md`.
- Native agent reads, discovery, searches, shell results, and tool results now distinguish visible truncation from bounded durable capture, support binary-safe exact record-scoped retrieval across restart, preserve source revisions and timeout prefixes, reconcile interrupted delivery outputs without replay, and explicitly refuse retention quota failures. Image reads deliver retained bytes through exact model and protocol support or return a visible limitation before full capture. Combined snapshots preserve output ownership and migrate separate model-selection and retained-output records safely.

### Fixed

- Cursor-left and Backspace no longer scan all preceding buffer text on each action. Line-boundary lookup searches backward in bounded chunks, and grapheme lookup reads only the final line while preserving Unicode and CRLF boundaries.
- Bounded agent command collection now terminates live producers before closing their Ports on timeout or capture exhaustion. Search and shell commands no longer continue consuming CPU after returning an incomplete result.

<!-- RELEASE_MARKER: new releases are prepended above this line -->
