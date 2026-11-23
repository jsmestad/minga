# Minga for Emacs Users

You love Emacs because you can modify *anything*. The advice system, hooks, buffer-local variables, live eval. No other editor comes close to that level of programmability.

So why would you look at something else?

Because everything in Emacs shares one thread and one address space. Every extension, every hook, every piece of advice competes for the same event loop. A slow hook freezes your editor. A global GC pause stutters your typing. Two packages can stomp on each other's state.

Minga keeps the programmability and fixes all of that.

---

## What you keep

The extensibility model you love transfers directly. Minga's runtime is the BEAM (the Erlang virtual machine) and Elixir is its Elisp.

| Emacs concept | Minga equivalent | Status |
|--------------|-----------------|--------|
| `defun` / `fset` (redefine behavior) | Commands, advice, hooks, and extension boundaries (module code updates take effect on restart per [ADR-0003](adr/0003-extension-code-updates-require-a-new-vm-generation.md)) | ✅ |
| `define-advice` (wrap any function) | `advise :before/:after/:around/:override` | ✅ |
| `add-hook` (attach to events) | `on :after_save, :after_open, :on_mode_change` | ✅ |
| Buffer-local variables | Per-process state (isolation enforced by VM) | ✅ |
| `M-:` / `eval-expression` | `Code.eval_string` / eval prompt | ✅ |
| `describe-function` / `describe-key` | `h/1`, `:sys.get_state`, runtime docs | ✅ |
| `init.el` is real Elisp | `config.exs` is real Elixir | ✅ |
| Major modes (filetype keymaps) | [Keymap scopes](KEYMAP-SCOPES.md) + `SPC m` filetype bindings | ✅ |
| Minor modes (toggleable keymaps) | Keymap layers with activation predicates | Future ([#216](https://github.com/jsmestad/minga/issues/216)) |
| MELPA packages | Hex packages, git repos, or local paths + supervised extensions | ✅ |

For the point-by-point proof that Elixir matches every property that makes Elisp powerful, read [Elixir is Minga's Elisp](EXTENSIBILITY.md).

---

## What's actually limiting about Emacs

### One slow hook freezes everything

```elisp
(add-hook 'after-save-hook #'my-format-and-lint)
```

If `my-format-and-lint` takes 3 seconds, your editor freezes for 3 seconds. Every save. You've tried `async.el` and `start-process`. They help, but they're brittle. Most packages don't bother.

**Minga:** Hooks run in their own BEAM processes. A 3-second hook never blocks your typing:

```elixir
on :after_save, fn _buf, path ->
  System.cmd("mix", ["format", path])
  System.cmd("mix", ["credo", "--strict", path])
end
# You're already typing while this runs.
```

### GC pauses are real

Emacs uses a stop-the-world garbage collector. When it runs, everything pauses. `gc-cons-threshold` tuning is a rite of passage. You shouldn't need to tune your garbage collector to get a smooth editing experience.

**Minga:** Each BEAM process has its own heap and garbage collector. A 10MB log file being GC'd has zero impact on the small config file you're actively editing.

### Everything shares one environment

`magit` can accidentally shadow a variable that `org-mode` depends on. A `use-package` `:config` block can throw an error that prevents the rest of your init from loading. You update a package, restart Emacs, and half your config is broken.

**Minga:** Every component is an isolated BEAM process. If a package fails, its supervisor handles recovery. You see an error message. Other packages don't even know it happened.

### The C core is a wall

Emacs is "written in Elisp," except for the display engine, regex engine, buffer internals, and redisplay loop. Those are C. When you need to change how rendering works or modify buffer data structures, you hit a wall.

**Minga:** Editor logic is Elixir all the way down: buffers, modes, motions, operators, keymap resolution, agent orchestration, and the render model. Native code lives strictly across explicit process boundaries for what it does best: Swift/Metal for macOS rendering, Go/Bubble Tea for the terminal frontend, and Zig for the tree-sitter parser and process helpers.

### AI agents need concurrency you don't have

You're using `gptel` or `ellama`. They make HTTP requests and stream responses in your single-threaded Elisp environment. A slow API response blocks your typing. Now imagine agentic tools that modify files, run shell commands, and operate autonomously for minutes.

**Minga:** Each AI agent session runs in its own supervised process tree. Agent file edits route through [in-memory buffer forks and staged changesets](BUFFER-AWARE-AGENTS.md) with revision checks, three-way merge, and undo integration. The BEAM's process model makes this architecturally natural.

---

## What you gain

### Modal editing (and CUA support)

You might already use `evil-mode`, an admission that Emacs's default keybindings cause RSI and Vim's modal model is more efficient. Minga gives you Vim-native modal editing without the impedance mismatch (alongside CUA editing support):

- Full normal/insert/visual/operator-pending modes
- Motions and text objects (`iw`, `i"`, `a{`)
- Space-leader keys with Which-Key popup (like Doom's `SPC` menus)
- Macros, registers, marks, dot repeat

If you use Doom Emacs, the leader key layout will feel familiar.

### Clean config reloads with explicit code generations

Emacs has `eval-buffer` and `load-file`, which often leave stale state or cached closures behind until you restart anyway.

In Minga, `SPC h r` reloads configuration options, keybindings, hooks, and advice cleanly in place. Compiled extension and user-module code follows an explicit generation boundary ([ADR-0003](adr/0003-extension-code-updates-require-a-new-vm-generation.md)): edits to compiled extension code validate in a disposable BEAM process and activate cleanly on restart rather than leaving half-updated modules in memory.

### Observability that Emacs can't match

Emacs has `describe-function` and `edebug`. The BEAM has a production-grade observability toolkit:

```elixir
:observer.start()                     # full GUI dashboard
:sys.get_state(MingaEditor)           # inspect any process live
:sys.get_state(buffer_pid)            # buffer state without stopping it

:dbg.tracer()
:dbg.p(Process.whereis(MingaEditor), [:receive])  # trace messages live
```

---

## The honest comparison

| Aspect | Elisp | Elixir |
|--------|-------|--------|
| **Execution model** | Single-threaded interpreter | Multi-process preemptive VM |
| **Behavior updates** | Immediate per-function `fset` | Live config/hook/advice reload; explicit VM generation for compiled extension updates ([ADR-0003](adr/0003-extension-code-updates-require-a-new-vm-generation.md)) |
| **Failure behavior** | Can leave editor in inconsistent state | Contained to one process |
| **Extension concurrency** | None (slow extension freezes editor) | Extensions are processes |
| **GC model** | Stop-the-world | Per-process (no global pauses) |
| **State model** | Global mutable state | Per-process state (isolated by default) |
| **Community packages** | MELPA (thousands) | Hex (large ecosystem, not editor-specific yet) |
| **Editor internals** | Elisp + C wall | Elixir core + thin native frontends/parser across ports |

The single real tradeoff: arbitrary compiled extension modules do not mutate in-place mid-session; they activate cleanly on a fresh process generation so module ownership and cleanup stay unambiguous.

---

## "But what about minor modes?"

If you're a Doom user, you rely on minor modes constantly. Minga doesn't have this yet. Here's why it's less of a gap than you'd expect.

Most of what minor modes do in Emacs, Minga handles differently:

- **LSP keybindings** live under `SPC c` globally. They no-op gracefully if no server is connected.
- **Git keybindings** live under `SPC g` after you install [GitExtended](CONFIGURATION.md#optional-extensions). Commands check for a Git repository.
- **Surround operations** are operators in operator-pending mode (`ds"`, `cs"'`).
- **Error navigation** (`]d`, `[d`) is always available. Does nothing if there are no diagnostics.

The Doom pattern of "always bind the key, let the command handle the empty case" works better than toggling keybindings on and off. When extensions mature enough to need toggleable keymap layers, the architecture is ready. See [#216](https://github.com/jsmestad/minga/issues/216).

---

## What you'd miss (honestly)

| Emacs has | Minga status |
|-----------|-------------|
| `org-mode` | In progress. See [minga-org](https://github.com/jsmestad/minga-org) for TODO cycling, checkbox toggling, heading promotion, and tree-sitter highlighting. |
| `magit` | Core Git status/diff/blame ship in `Minga.Git`; richer interactive Git workflows ship via the optional [GitExtended](CONFIGURATION.md#optional-extensions) extension. |
| LSP (`eglot` / `lsp-mode`) | ✅ Shipped. Supervised LSP clients (`Minga.LSP.Client`) provide diagnostics, hover, definitions, completion, code actions, and rename. |
| MELPA packages | ✅ Extensions install from Hex packages, git repos, or local paths. Supervised, crash-isolated, with update and rollback. |
| `projectile` | ✅ Project detection, `SPC p` group. See [Projects](PROJECTS.md). |
| Emacs Lisp (if you love Lisp) | Elixir. |

`org-mode` is the feature that keeps most Emacs users from leaving. That's exactly why [minga-org](https://github.com/jsmestad/minga-org) exists. It's an extension (installed via `extension :minga_org, git: "..."` in your config) that ships tree-sitter highlighting for org files, TODO keyword cycling, checkbox toggling, and heading manipulation. It's early, but it proves the extension system works for real use cases and that org support doesn't have to live inside the editor core.

For code editing, the thing you actually spend most of your time doing, Minga offers the same deep programmability with an architecture that eliminates the concurrency, isolation, and observability gaps you've been working around for years.

---

## The bet

Emacs is the most programmable editor ever built. That's why you use it, despite the single-threaded freezes, the GC pauses, the package conflicts, and the C core you can't touch.

Minga keeps the programmability and fixes everything else. Same depth of customization. Structural isolation between components. True concurrency. Per-process garbage collection. No C wall. Modal editing.

Same philosophy. Better runtime.
