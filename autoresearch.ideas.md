# Autoresearch Ideas: Test Flakiness

- **FileFind.Backend behaviour**: Same pattern as Git.Backend. `FileFind.list_files` calls `fd`/`git ls-files`/`find` via System.cmd. A stub returning canned file lists would eliminate these spawns from async tests.
- **ProjectSearch.Backend behaviour**: `ProjectSearch.search` calls `rg`/`grep`. Stub could return canned search results.
- **Extension.Git backend extraction**: `Extension.Git` has its own `git/2` helper calling System.cmd directly (clone, fetch, checkout). Could go through a shared backend or its own.
- **Minga.Project.recent_files race**: The `ProjectTest` "no-op when no project root is set" test fails intermittently because `Project.recent_files` leaks state across tests via the global Project GenServer. Separate issue from erl_child_setup but contributes to test_failures count.
- **Buffer.Server.set_filetype reseeds all options**: When `set_filetype` is called, it reseeds ALL buffer options from global Config.Options, overwriting any per-buffer overrides. This could re-introduce clipboard leakage if any code path triggers filetype detection after EditorCase sets clipboard:none.
