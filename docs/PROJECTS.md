# Projects

Minga automatically detects your project root when you open a file, remembers projects you've visited, and scopes file finding and search to the current project. If you've used projectile in Doom Emacs, this will feel familiar.

## How project detection works

When you open a file, Minga walks up from that file's directory looking for marker files that signal a project root. The first match wins. These markers are checked in order:

| Marker | Project type |
|--------|-------------|
| `.git` | Git repository |
| `mix.exs` | Elixir/Mix |
| `Cargo.toml` | Rust/Cargo |
| `package.json` | Node.js |
| `go.mod` | Go |
| `pyproject.toml` | Python |
| `setup.py` | Python |
| `Gemfile` | Ruby |
| `build.zig` | Zig |
| `.minga` | Manual sentinel |

The `.minga` sentinel is useful for directories that don't have a standard build tool marker. Drop an empty `.minga` file in any directory and Minga will treat it as a project root.

Once detected, the project root is stored for the current session and used to scope file finding (`SPC p f`, `SPC f f`) and project search (`SPC s p`, `SPC /`).

## Known projects

Every project root Minga detects gets added to a known-projects list, persisted at `~/.config/minga/known-projects`. This list survives editor restarts, so `SPC p p` (switch project) shows all projects you've ever visited.

The file is plain text, one absolute path per line. You can edit it manually if you want to clean it up. Minga filters out directories that no longer exist when it loads the list.

## Keybindings

All project commands live under the `SPC p` prefix:

| Binding | Command | What it does |
|---------|---------|-------------|
| `SPC p f` | Find file in project | Opens the file finder scoped to the current project root |
| `SPC p p` | Switch project | Shows all known projects; selecting one switches the root and opens the file finder |
| `SPC p i` | Invalidate cache | Clears the cached file list and rebuilds it from disk |
| `SPC p a` | Add project | Adds the current project root to the known-projects list |
| `SPC p d` | Remove project | Removes the current project root from the known-projects list |

`SPC f f` and `SPC s p` are also project-aware. They scope to the detected project root instead of the working directory.

## File cache

Minga caches the file list for the current project so the file finder opens instantly. The cache is built in the background using `fd`, `git ls-files`, or `find` (whichever is available, in that order). It respects `.gitignore` patterns when using `fd` or `git ls-files`.

The cache rebuilds automatically when you switch projects or detect a new one. Use `SPC p i` to force a rebuild, for example after creating new files outside the editor.

## Architecture

`Minga.Project` is a GenServer in the supervision tree. It holds three things in its process state:

1. The current project root and type
2. The cached file list (populated by a background `Task`)
3. The persisted known-projects list

Project root detection is handled by `Minga.Project.Detector`, a pure module with no process state. The same detection logic is shared with the LSP subsystem (via `Minga.LSP.RootDetector`), so your language server and your file finder always agree on what the project root is.

The file cache lives in GenServer state rather than ETS. Only one consumer (the picker) reads it at a time, so a GenServer is simpler and sufficient. Cache rebuilds shell out to `fd`/`git ls-files` in a separate `Task` so the GenServer stays responsive while the rebuild is in progress.

## Nested projects

In umbrella or monorepo setups, Minga finds the *nearest* project root. If you have:

```
myapp/
  mix.exs
  apps/
    web/
      mix.exs
      lib/
        router.ex
```

Opening `router.ex` detects `apps/web/` as the project root (not `myapp/`), because that's the nearest directory containing `mix.exs`. This matches projectile's behavior.

## Differences from projectile

Minga's project system covers the core projectile workflow but doesn't implement everything:

| Feature | Status |
|---------|--------|
| Auto-detect project root | ✅ |
| Persist known projects | ✅ |
| `SPC p f` (find file) | ✅ |
| `SPC p p` (switch project) | ✅ |
| `SPC p i` (invalidate cache) | ✅ |
| `SPC p !` (run command in root) | Planned (needs terminal integration) |
| `SPC p t` (terminal in root) | Planned (needs terminal emulator) |
| `SPC p R` (recent files in project) | Planned |
| Per-project file cache | Current project only; switching rebuilds |
