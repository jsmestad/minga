# Update screen snapshots

Update baselines only after an intentional UI change. An unexpected snapshot difference is a regression to investigate, not permission to replace the expected output.

1. Run the affected tests under `test/minga_editor/integration/` and inspect each failure's screen diff.
2. When every difference matches the intended change, regenerate the baselines from the repository root:

   ```bash
   UPDATE_SNAPSHOTS=1 mix test test/minga_editor/integration/
   ```

3. Review the changed files under `test/snapshots/minga_editor/integration/`. Check text, cursor position, cursor shape, and mode, not just whether the command passed.
4. Run the tests without the update flag so incorrect baselines cannot silently replace themselves:

   ```bash
   mix test.llm test/minga_editor/integration/
   ```

5. Commit the reviewed `.snap` files with the UI change.

For a focused update, use the actual test file or line instead of the directory, for example:

```bash
UPDATE_SNAPSHOTS=1 mix test test/minga_editor/integration/snapshot_test.exs
mix test.debug test/minga_editor/integration/snapshot_test.exs
```

See [Snapshot Testing](../SNAPSHOT_TESTING.md) for the file format and `assert_screen_snapshot` examples.
