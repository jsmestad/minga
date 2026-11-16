# Add or modify an agent tool

File tools must see the user's open buffers and keep agent changes isolated until acceptance. Route file content operations through the same boundary as the existing tools.

Agent tools live in `lib/minga_agent/tools/`. When adding or modifying a tool that reads or writes file content:

1. **File tools route through `MingaAgent.ToolRouter`.** Reads and mutations select the session's actual owned buffer, fork, or changeset, including unsaved content. Mutations call `conditional_mutate/4`; the selected owner checks the expected full-source revision and commits the complete file change in one callback. Native headless sessions create an owned view too. An unavailable route is an error, never permission to write directly to disk. See [Buffer-aware agents](../BUFFER-AWARE-AGENTS.md#atomic-file-edits) for matching, undo, and publication rules.
2. **Do not reintroduce context artifact writing without a reader.** The old writer saved `.minga/context/session-summary-*` files that no code loaded. Add an explicit picker or loader before adding any new writer.
3. **Batch edits into a single call** rather than making N separate calls. One call means one undo entry and one version bump.
4. **Test the tool function** in its test under `test/minga_agent/tools/`. Assert observable content, isolation, and error behavior rather than mock forwarding.

For example, a change to the edit tool uses:

```bash
mix test.debug test/minga_agent/tools/edit_file_test.exs
```

Use the corresponding read or write tool test for changes to those tools.
