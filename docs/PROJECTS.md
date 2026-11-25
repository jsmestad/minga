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

The `.minga` sentinel is useful for directories that don't have a standard build tool marker. Drop an empty `.minga` file in any directory and Minga will treat it as a project root. A `.minga` directory marks a project root too: that is where a project keeps its own `AGENTS.md` and skills for Minga. The one place it does not count is a folder too broad to be a project (your home directory, `/`, the top of a mounted volume), because Minga keeps its own data in a `.minga` directory in your home directory.

Once detected, the project root is stored for the current session and used to scope file finding (`SPC p f`, `SPC f f`) and project search (`SPC s p`, `SPC /`).

## Where Minga works when there is no project

Not every file lives in a project. A note in a scratch folder, a config file, a script on the desktop: none of them has a marker above it. When you ask Minga to work on such a file, it still needs one folder to read, search, edit and run commands in. It picks that folder once, when the conversation starts, in this order:

1. The detected project, if there is one.
2. The folder you opened the editor on.
3. The folder of the file you started from.

The conversation says where it landed: "Minga is working in ~/notes. No project was detected there." Relative paths you mention resolve against that folder, and shell commands run there.

Minga never falls back to the directory the editor process happened to start in. For an app started from Finder or the Dock that directory is `/`, which is not a folder you chose.

Two cases leave Minga with no folder at all:

- **Nothing is open.** No project, no folder and no file. The conversation says "Minga has no folder to work in. Open a file or a folder."
- **The only candidate is too broad.** A file that sits directly in your home directory, in a folder above it, in `/`, or at the top of a mounted volume would make that whole tree Minga's workspace. Minga declines and says so: "Minga has no folder to work in: ~ is too broad. Open a folder inside it, or move the file into a folder." Another name for the same place does not get around this: the folder is compared by its real path and by the directory itself, so a symlink, a different case, or a second mount of the same volume is just as broad. Minga never substitutes your home directory.

Nothing has failed in either case, and the conversation still works for questions. Every tool that could reach your files answers with that same sentence until there is a folder: reading and editing, search, Git, the language server, shell commands, subagents, MCP servers and extension tools. The declined calls show as "Denied", not as errors. What still works is what cannot touch your files: asking you a question, the checklist, describing Minga, reading memory and fetching a URL. To give Minga one, open a file inside a folder (or open the folder) and start a new conversation; a conversation keeps the folder it started with, and one that started without a folder stays that way, including when Minga restarts its session.

If you want a loose folder to behave like a project, drop an empty `.minga` file in it.

A marker does not make a too-broad folder acceptable to Minga's Agent, with one exception: version control. If your home directory is a Git repository (a dotfiles setup, for example), it is a project and the Agent works in it, because the whole tree really is one project. A stray `package.json`, a `mix.exs` or a `.minga` file in your home directory is not that kind of evidence, and the Agent still says the folder is too broad. The file tree and project search are not affected: they follow the detected project as before.

### A conversation keeps its folder

The folder is part of the conversation, not of the editor window. A saved conversation records it. When you restore the conversation while that folder is the one you have open, it picks up where it left off.

A conversation cannot move to another folder, and the reason is in how it continues. Minga's instructions to the model name the folder, and a conversation can only go on under the instructions it ran with. Change the folder and the earlier turns no longer belong to what the model is told now. The tools, hooks and staged edits of the window you are in belong to its folder, too. So Minga never lets a restored conversation act somewhere it did not start, and it never moves the window's Agent to follow a conversation.

What happens when you restore a conversation somewhere else is plain: you can read it, and it tells you where it belongs. "This conversation can only be read here. Start a new conversation, or restore it in ~/code/api." A notification offers **New conversation** (click it, or press the key it names). If you send a message anyway, you get the same sentence and your draft is kept.

Conversations saved before Minga recorded the folder still carry it, because the instructions they ran with were saved with them. Minga reads the folder from those saved instructions, never from your messages or from tool output, and records it from then on.

A few restored conversations cannot continue anywhere:

- **The folder is gone.** The record keeps the path, so the conversation works again once the folder is back.
- **It ran somewhere too broad.** A conversation from before these rules may have run in your home directory or in `/`. Minga does not work there any more, unless the folder is under version control.
- **Its record names no folder.** Rare: the saved instructions do not name one.

A conversation that started without a folder comes back the same way. It still works for questions when you restore it the way it started: with nothing open, or from the same place that was too broad.

## Known projects

When you switch to a project, Minga remembers its root so you can return to it with `SPC p p`. The list survives restarts in `$XDG_CONFIG_HOME/minga/known-projects`, or `~/.config/minga/known-projects` if `XDG_CONFIG_HOME` is not set. Development builds use `known-projects-dev` in the same directory, so source launches don't change the installed editor's list.

The file is plain text, one absolute path per line. Quit Minga before editing the list by hand so a running editor can't write its old list back. Minga skips directories that no longer exist when it loads the list.

## Keybindings

All project commands live under the `SPC p` prefix. These bindings are aligned with Doom Emacs:

| Binding | Command | What it does |
|---------|---------|-------------|
| `SPC SPC` | Find file in project | Opens the file finder scoped to the current project root |
| `SPC p f` | Find file in project | Same as `SPC SPC` |
| `SPC p p` | Switch project | Shows all known projects; selecting one switches the root and opens the file finder |
| `SPC p r` | Recent files | Shows recently opened files in the current project, most recent first |
| `SPC p .` | Browse project | Opens or focuses the file tree for the current project |
| `SPC p T` | Test project | Runs the project test command if a test runner is detected |
| `SPC p i` | Invalidate cache | Clears the cached file list and rebuilds it from disk |
| `SPC p a` | Add project | Adds the current project root to the known-projects list |
| `SPC p d` | Remove project | Removes the current project root from the known-projects list |

`SPC f f` and `SPC s p` are also project-aware. They scope to the detected project root instead of the working directory.

## Recent files

Every file you open gets recorded in a per-project recent files list. `SPC p r` shows this list with the most recently opened file at the top. Recent files are scoped per project, so switching projects shows a different list.

By default, recent file history is persisted to `~/.config/minga/recent-files` so it survives editor restarts. The file format is tab-separated: one `root<TAB>relative_path` per line.

Two config options control this behavior:

```elixir
# In ~/.config/minga/config.exs
set :recent_files_limit, 200       # max entries per project (default: 200)
set :persist_recent_files, false   # disable writing history to disk
```

When `persist_recent_files` is `false`, recent files still work within a session (tracked in memory) but nothing is written to or read from disk. This is useful if you don't want file access history on disk for privacy or cleanliness reasons.

## File cache

Minga caches the file list for the current project so the file finder opens instantly. The cache is built in the background using `fd`, `git ls-files`, or `find` (whichever is available, in that order). It respects `.gitignore` patterns when using `fd` or `git ls-files`.

The cache rebuilds automatically when you switch projects or detect a new one. Use `SPC p i` to force a rebuild, for example after creating new files outside the editor.

## File tree visual quality

The file tree is the project cockpit: it shows root context, hierarchy, active file, selection, focus, dirty buffers, git state, diagnostics, and common actions in one surface.

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
| `SPC SPC` / `SPC p f` (find file) | ✅ |
| `SPC p p` (switch project) | ✅ |
| `SPC p r` (recent files in project) | ✅ |
| `SPC p .` (browse project) | ✅ |
| `SPC p T` (test project) | ✅ |
| `SPC p i` (invalidate cache) | ✅ |
| `SPC p !` / `SPC p &` (run command in root) | Planned (needs terminal integration) |
| `SPC p c` (compile project) | Planned (needs compile abstraction) |
| `SPC p k` (kill project buffers) | Planned |
| `SPC p s` (save project buffers) | Planned |
| Per-project file cache | Current project only; switching rebuilds |
