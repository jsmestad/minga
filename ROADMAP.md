# Minga Roadmap

Current status and planned features. Updated as development progresses.

✅ = Implemented  🚧 = In Progress  📋 = Planned  💭 = Considering

---

## Core Editing

| Feature | Status | Notes |
|---------|--------|-------|
| Gap buffer with cursor movement | ✅ | Byte-indexed positions for performance |
| Insert / delete / backspace | ✅ | Full Unicode support |
| Undo / redo | ✅ | Per-buffer undo stack |
| Dot repeat (`.`) | ✅ | Replays last change |
| Count prefix (`3dd`, `5j`) | ✅ | Works with motions and operators |
| Auto-pairing (`()`, `""`, etc.) | ✅ | |
| Join lines (`J`) | ✅ | |
| Indent / dedent (`>>`, `<<`) | ✅ | |
| Toggle case (`~`) | ✅ | |
| Line numbers (absolute / relative) | ✅ | Togglable via `:set nu` / `:set rnu` |
| Diff-based undo (memory efficient) | 📋 | Currently stores full snapshots |
| Line index cache (O(1) line access) | 📋 | See `docs/PERFORMANCE.md` |

## Modes

| Mode | Status | Notes |
|------|--------|-------|
| Normal | ✅ | Full modal editing with 100+ key bindings |
| Insert | ✅ | With auto-pair support |
| Visual (characterwise) | ✅ | Selection + operators |
| Visual Line | ✅ | Full-line selection |
| Operator-Pending | ✅ | `d`, `c`, `y` + motion/text object |
| Command (`:`) | ✅ | Ex commands with parsing |
| Search (`/`, `?`) | ✅ | Forward and backward |
| Replace (`r`) | ✅ | Single-character replace |
| Substitute confirm | ✅ | `:%s/old/new/gc` interactive |
| Visual Block | 📋 | Column selection |

## Motions

| Motion | Status | Notes |
|--------|--------|-------|
| `h` `j` `k` `l` | ✅ | Basic movement |
| `w` `b` `e` | ✅ | Word motions |
| `W` `B` `E` | ✅ | WORD motions (whitespace-delimited) |
| `0` `$` | ✅ | Line start / end |
| `^` | ✅ | First non-blank |
| `gg` / `G` | ✅ | Document start / end |
| `f`/`F`/`t`/`T` + char | ✅ | Find character on line |
| `{` `}` | ✅ | Paragraph forward / backward |
| `%` | ✅ | Matching bracket |
| `;` `,` (repeat find) | 📋 | Stubbed, not yet wired |
| `H` `M` `L` | 📋 | Screen top / middle / bottom |

## Operators

| Operator | Status | Notes |
|----------|--------|-------|
| `d` (delete) | ✅ | With motions and text objects |
| `c` (change) | ✅ | Delete + enter insert mode |
| `y` (yank) | ✅ | Copy to register |
| `dd` / `cc` / `yy` | ✅ | Linewise variants |
| `p` / `P` | ✅ | Paste after / before |
| `x` / `X` | ✅ | Delete char under / before cursor |
| `D` / `C` | ✅ | Delete / change to end of line |
| `>>` / `<<` | ✅ | Indent / dedent |

## Text Objects

| Text Object | Status | Notes |
|-------------|--------|-------|
| `iw` / `aw` | ✅ | Inner / a word |
| `i"` / `a"` | ✅ | Inner / a double-quoted string |
| `i'` / `a'` | ✅ | Inner / a single-quoted string |
| `` i` `` / `` a` `` | ✅ | Inner / a backtick string |
| `i(` / `a(` | ✅ | Inner / a parentheses |
| `i[` / `a[` | ✅ | Inner / a brackets |
| `i{` / `a{` | ✅ | Inner / a braces |
| `i<` / `a<` | ✅ | Inner / a angle brackets |
| `it` / `at` | 📋 | Inner / a HTML tag |
| `ip` / `ap` | 📋 | Inner / a paragraph |
| `is` / `as` | 📋 | Inner / a sentence |

## Leader Key (`SPC`) Commands

| Binding | Command | Status |
|---------|---------|--------|
| `SPC :` | Command palette | ✅ |
| `SPC f f` | Find file (fuzzy picker) | ✅ |
| `SPC f s` | Save file | ✅ |
| `SPC b b` | Switch buffer (picker) | ✅ |
| `SPC b n` / `SPC b p` | Next / previous buffer | ✅ |
| `SPC b d` | Kill buffer | ✅ |
| `SPC b m` | View messages | ✅ |
| `SPC b s` | Switch to scratch | ✅ |
| `SPC b N` | New empty buffer | ✅ |
| `SPC s p` / `SPC /` | Search project (ripgrep) | ✅ |
| `SPC t l` | Toggle line number style | ✅ |
| `SPC w h/j/k/l` | Window navigation | ✅ | Directional focus movement |
| `SPC w v` / `SPC w s` | Vertical / horizontal split | ✅ | Nested splits supported |
| `SPC w d` | Close window | ✅ | Last window protected |
| `SPC h k` | Describe key | 📋 | Stubbed |
| `SPC q q` | Quit | ✅ |

## Ex Commands (`:`)

| Command | Status | Notes |
|---------|--------|-------|
| `:w` / `:w!` | ✅ | Save / force save |
| `:q` / `:q!` | ✅ | Quit / force quit |
| `:wq` | ✅ | Save and quit |
| `:e <file>` / `:e!` | ✅ | Open file / force reload |
| `:new` / `:enew` | ✅ | New empty buffer |
| `:%s/old/new/g` | ✅ | Substitution with `g`, `c` flags |
| `:set nu` / `:set rnu` | ✅ | Line number options |
| `:reload-highlights` | ✅ | Re-apply syntax highlighting |
| `:checktime` | ✅ | Check for external file changes |

## Syntax Highlighting

| Feature | Status | Notes |
|---------|--------|-------|
| Tree-sitter integration | ✅ | Parsing runs in Zig process |
| 24 compiled-in grammars | ✅ | Elixir, Ruby, JS, TS, Go, Rust, Python, Zig, and 16 more |
| Doom One color theme | ✅ | Built-in default theme |
| User-overridable queries | ✅ | `~/.config/minga/queries/{lang}/highlights.scm` |
| Runtime grammar loading | ✅ | `dlopen` for user grammars |
| Background query pre-compilation | ✅ | All 23 query sets compiled on startup |
| Per-buffer highlight cache | ✅ | Instant switching between files |
| Additional themes | 📋 | Only Doom One currently |
| Theme switching at runtime | 📋 | |
| Incremental parsing | 💭 | Full reparse is <5ms for 10K lines; not needed yet |

## File Management

| Feature | Status | Notes |
|---------|--------|-------|
| Open / save / save-as | ✅ | |
| Fuzzy file finder | ✅ | `SPC f f` with incremental search |
| Buffer list picker | ✅ | `SPC b b` |
| Project search (ripgrep) | ✅ | `SPC s p` / `SPC /` |
| File change detection | ✅ | Watches open files, prompts on conflict |
| Filetype detection | ✅ | By extension, with registry |
| Multiple buffers | ✅ | Open several files, switch between them |
| Dirty buffer protection | ✅ | Warns before quitting with unsaved changes |
| Global / buffer-local options | 📋 | Per-buffer overrides with filetype defaults (see [Architecture](docs/ARCHITECTURE.md)) |

## Registers & Macros

| Feature | Status | Notes |
|---------|--------|-------|
| Named registers (`"a`–`"z`) | ✅ | Yank/delete into specific registers |
| Default register (`""`) | ✅ | |
| Black hole register (`"_`) | ✅ | Delete without saving |
| System clipboard (`"+`) | ✅ | |
| Macro recording (`q{a-z}`) | ✅ | Record and replay key sequences |
| Macro replay (`@{a-z}`, `@@`) | ✅ | Including repeat-last |

## Marks

| Feature | Status | Notes |
|---------|--------|-------|
| Set marks (`m{a-z}`) | ✅ | Per-buffer marks |
| Jump to mark line (`'{a-z}`) | ✅ | |
| Jump to mark exact (`` `{a-z} ``) | ✅ | |
| Special marks (`''`, ` `` `) | ✅ | Jump to last position |
| Global marks (`A-Z`) | 📋 | Cross-buffer marks |

## UI

| Feature | Status | Notes |
|---------|--------|-------|
| Zig + libvaxis renderer | ✅ | High-performance TUI |
| Modeline (status bar) | ✅ | Mode, file, position, dirty indicator |
| Which-Key popup | ✅ | Shows available keys after `SPC` |
| Picker with fuzzy matching | ✅ | Used for files, buffers, commands, search results |
| Viewport scrolling | ✅ | Vertical and horizontal |
| Mouse support | ✅ | Click to position cursor |
| Split windows | ✅ | Vertical, horizontal, nested; `SPC w` navigation |
| Floating windows | 📋 | Zig renderer supports panels |
| Tab bar | 💭 | |

## LSP & Diagnostics

| Feature | Status | Notes |
|---------|--------|-------|
| Source-agnostic diagnostic framework | ✅ | `Minga.Diagnostics` — any producer (LSP, linters, compilers) publishes via unified API |
| LSP server registry | ✅ | Hardcoded defaults for 16 languages (Elixir, Go, Rust, C/C++, JS/TS, Python, etc.) |
| LSP client GenServer | ✅ | Port-based spawn, initialize handshake, capability + offset encoding negotiation |
| Multi-server per buffer | ✅ | e.g., typescript-language-server + eslint on same file |
| Document sync (full) | ✅ | `didOpen`, debounced `didChange` (150ms), `didSave`, `didClose` |
| Diagnostic gutter signs | ✅ | 2-char sign column: `E`/`W`/`I`/`H` in Doom One colors |
| Diagnostic navigation | ✅ | `]d` / `[d` next/prev, `SPC c d` picker |
| Minibuffer diagnostic hint | ✅ | Shows message when cursor is on a diagnostic line |
| `:LspInfo` command | ✅ | Server name, status, encoding in minibuffer |
| LSP DynamicSupervisor | ✅ | One client per (server, root), crash recovery |
| Completion | 📋 | |
| Go-to-definition | 📋 | |
| Hover | 📋 | |
| Rename | 📋 | |
| Incremental document sync | 📋 | Full sync for now; incremental when perf requires it |

## Infrastructure

| Feature | Status | Notes |
|---------|--------|-------|
| OTP supervision tree | ✅ | `rest_for_one` — renderer crash doesn't lose state |
| Port protocol (BEAM ↔ Zig) | ✅ | Length-prefixed binary, typed opcodes |
| Headless test harness | ✅ | Full editor testing without terminal |
| Custom Mix compiler for Zig | ✅ | `mix compile` builds everything |
| 1,659 Elixir tests | ✅ | Including property-based tests |
| 105 Zig tests | ✅ | Protocol + renderer + highlighter |
| Burrito packaging | ✅ | Single-binary distribution |

---

## What's Next

Roughly in priority order:

1. ~~**Split windows**~~ — ✅ Done
2. ~~**LSP client (diagnostics)**~~ — ✅ Foundation + diagnostics shipped. Completion, go-to-definition, hover, rename are next.
3. **Plugin system** — Elixir-based plugins that run as supervised processes
4. **Additional themes** — Theme loading from disk, runtime switching
5. **Visual block mode** — Column selection and editing
6. **File tree sidebar** — Project navigation panel
7. **Git integration** — Gutter indicators, blame, hunk staging
8. **Terminal emulator** — Embedded terminal in a split

---

## Design Principles

These guide what we build and how:

- **Fault tolerance over speed** — The BEAM's supervision model means crashes are recoverable events, not catastrophes
- **Two-process isolation** — Editor state and rendering never share memory; either can fail independently
- **Vim grammar, modern UX** — Modal editing with discoverable leader-key menus
- **Elixir for logic, Zig for pixels** — Each language where it excels
- **Test everything** — 1,659 tests and counting; property-based tests for data structures
