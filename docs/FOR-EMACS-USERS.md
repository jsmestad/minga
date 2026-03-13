# Minga for Emacs Users

You love Emacs because you can modify *anything*. The advice system, hooks, buffer-local variables, live eval. No other editor comes close to that level of programmability. So why would you even look at something else?

**Because everything in Emacs shares one thread and one address space.** Every extension, every hook, every piece of advice competes for the same event loop. A slow hook freezes your editor. A global GC pause stutters your typing. Two packages can stomp on each other's state. You've accepted these trade-offs because nothing else offered the same extensibility.

Minga does. Without the trade-offs.

---

## What you keep

The extensibility model you love transfers directly. Minga's runtime is the BEAM (the Erlang virtual machine) and Elixir is its Elisp.

| Emacs concept | Minga equivalent | Status |
|--------------|-----------------|--------|
| `defun` / `fset` (redefine anything) | Hot code reloading (swap modules at runtime) | ✅ |
| `define-advice` (wrap any function) | `advise :before/:after/:around/:override` | ✅ |
| `add-hook` (attach to events) | `on :after_save, :after_open, :on_mode_change` | ✅ |
| Buffer-local variables | Per-process state (isolation enforced by VM) | ✅ |
| `M-:` / `eval-expression` | `Code.eval_string` / eval prompt | ✅ |
| `describe-function` / `describe-key` | `h/1`, `:sys.get_state`, runtime docs | ✅ |
| `init.el` is real Elisp | `config.exs` is real Elixir | ✅ |
| Major modes (filetype keymaps) | [Keymap scopes](KEYMAP-SCOPES.md) + `SPC m` prefix scoped to filetype | ✅ ([#223](https://github.com/jsmestad/minga/issues/223), [#215](https://github.com/jsmestad/minga/issues/215)) |
| Minor modes (toggleable keymaps) | Keymap layers with activation predicates | Future ([#216](https://github.com/jsmestad/minga/issues/216)) |
| MELPA packages | Hex packages + supervised extensions | Future |

Every property that makes Emacs Emacs, Minga is building on the BEAM. The [Elixir as Elisp](EXTENSIBILITY.md) doc proves it point by point.

---

## What's actually limiting about Emacs

You know these problems. You've just decided they're worth it. But they don't have to be.

### 1. One slow hook freezes everything

```elisp
(add-hook 'after-save-hook #'my-format-and-lint)
```

If `my-format-and-lint` takes 3 seconds, your editor freezes for 3 seconds. Every save. You can't type, you can't scroll, you can't switch buffers. Emacs is single-threaded. Your hooks, your commands, your rendering: all on one thread.

You've tried workarounds. `async.el`. `emacs-async`. Shelling out with `start-process`. They help, but they're brittle. Coordinating async results back into the single-threaded Elisp environment is error-prone, and most packages don't bother.

**Minga:** Hooks run in their own BEAM processes. The editor's main loop never blocks:

```elixir
on :after_save, fn _buf, path ->
  # This takes 3 seconds. Your editor doesn't care.
  # It's running in a separate process.
  System.cmd("mix", ["format", path])
  System.cmd("mix", ["credo", "--strict", path])
end
```

This isn't async bolted on. The BEAM's preemptive scheduler runs all processes concurrently with fairness guarantees. Your typing always gets CPU time, even if a hook is doing heavy work.

### 2. GC pauses are real

Emacs uses a stop-the-world garbage collector. When it runs, everything pauses: rendering, input handling, all of it. With large buffers or many packages loaded, you've felt the stutters. `gc-cons-threshold` tuning is a rite of passage for Emacs users. You shouldn't need to tune your garbage collector to get a smooth editing experience.

**Minga:** Each BEAM process has its own heap and its own garbage collector. When a large buffer's process collects garbage, it doesn't pause the editor, the renderer, or any other buffer. A 10MB log file being GC'd has zero impact on the small config file you're actively editing.

### 3. Everything shares one environment

Emacs has no isolation. Every package, every hook, every piece of advice shares one Elisp environment. `magit` can accidentally shadow a variable that `org-mode` depends on. A `use-package` `:config` block can throw an error that prevents the rest of your init from loading.

You update a package, restart Emacs, and your `init.el` fails halfway through. You're dropped into a half-configured editor with broken keybindings and missing modes. Or a package runs fine for weeks, then hits an edge case that corrupts a buffer's undo history or leaves `after-save-hook` in a broken state.

**Minga:** Every component is an isolated BEAM process. Packages run in their own supervised process trees. A git integration package can't affect your buffer state because they're in different processes with different memory. If a package fails, its supervisor handles recovery. You see an error message in the status bar. Your editing session continues. Other packages don't even know anything happened.

### 4. The C core is a wall

Emacs is "written in Elisp," except for the parts that aren't. The display engine, the regex engine, buffer internals, the redisplay loop: these are C. When you need to change how rendering works, or fix a display bug, or modify buffer data structures, you hit a wall. The C core isn't practically modifiable by users.

This creates two classes of functionality: things you can customize (Elisp layer) and things you can't (C core). You've worked around C-level limitations by writing increasingly clever Elisp, but the wall is always there.

**Minga:** The editor logic is Elixir all the way down. Buffers, modes, motions, operators, commands, the keymap trie, the renderer pipeline: it's all Elixir modules you can read, understand, and replace at runtime. The only non-Elixir boundary is the Zig renderer, and that's on the other side of a process boundary by design. It handles pixels, not editor logic.

### 5. AI agents need concurrency you don't have

You're using `gptel` or `ellama` or `org-ai`. They make HTTP requests to LLM APIs, stream responses into buffers, and sometimes execute code. All of this happens in your single-threaded Elisp environment. A slow API response blocks your typing. Concurrent modifications to the same buffer have no serialization guarantees.

Now imagine agentic tools that don't just chat but modify files, run shell commands, create buffers, and operate autonomously for minutes. In Emacs, all of that contends with your typing for the same thread.

**Minga:** Each AI agent session is its own supervised process tree. It communicates with buffers via message passing, the same mechanism the editor itself uses. An agent can't interfere with buffer state because it doesn't have direct access to buffer memory. The BEAM's preemptive scheduler guarantees your typing is always responsive regardless of what agents are doing. You can run multiple agents on multiple buffers simultaneously, and you can inspect any agent's live state with `:sys.get_state(agent_pid)`.

And Minga is going further: agent tools are being [wired to edit buffers in-memory](BUFFER-AWARE-AGENTS.md) instead of writing to the filesystem. Agent edits will go through the same `Buffer.Server` GenServer as your keystrokes, with full undo integration, incremental tree-sitter sync, and no "file changed on disk" prompts. Multiple agents will be able to work on the same file concurrently via buffer forking with three-way merge, replacing the need for git worktrees. This is something no editor does today, and the BEAM's process model makes it architecturally natural.

---

## What you gain

Beyond addressing Emacs's limitations:

### Modal editing (yes, really)

You might already use `evil-mode`, an admission that Emacs's default keybindings cause RSI and Vim's modal model is more efficient. Minga gives you Vim-native modal editing without the impedance mismatch of running a Vim emulation layer on top of a non-modal editor:

- Full normal/insert/visual/operator-pending modes
- `d`, `c`, `y` + motions and text objects (`iw`, `i"`, `a{`, etc.)
- Space-leader keys with Which-Key popup (like Doom's `SPC` menus)
- Macros, registers, marks, dot repeat

If you use Doom Emacs, the leader key layout will feel familiar.

### Hot code reloading that actually works

Emacs has `eval-buffer` and `load-file`. They work, but reloading a package often requires restarting because of stale state, cached closures, and order-dependent initialization.

The BEAM was designed for hot code upgrades in production systems. It manages two versions of a module simultaneously. Old calls finish on the old version, new calls use the new code. Reload your config with `SPC h r` and the editor applies changes cleanly. No restart. No stale state.

### Observability that Emacs can't match

Emacs has `describe-function` and `edebug`. Useful, but limited.

The BEAM has a production-grade observability toolkit:

```elixir
# Full GUI showing every process, memory, CPU, message queues
:observer.start()

# Inspect any process's state without stopping it
:sys.get_state(Minga.Editor)
:sys.get_state(buffer_pid)

# Trace every message a process receives, live
:dbg.tracer()
:dbg.p(Process.whereis(Minga.Editor), [:receive])

# See all buffer processes and their memory usage
DynamicSupervisor.which_children(Minga.Buffer.Supervisor)
```

This exists because the BEAM was built for systems that run 24/7 and must be debuggable without stopping. You get telecom-grade introspection for free.

---

## Elixir is Minga's Elisp

This is the part that matters most to Emacs users. You need proof that Elixir can replace Elisp, not just for config, but for the deep programmability that makes Emacs what it is.

Here's the point-by-point comparison across every property that makes Elisp powerful:

### 1. Redefine any function at runtime ✅

**Elisp:**
```elisp
(defun my-custom-word-forward ()
  "Jump to next camelCase boundary."
  (interactive)
  (re-search-forward "[A-Z]" nil t))

(fset 'forward-word #'my-custom-word-forward)
```

**Elixir:**
```elixir
defmodule MyMotion do
  def word_forward(buffer, pos) do
    find_next_uppercase(buffer, pos)
  end
end

Minga.Config.override(Minga.Motion.Word, :word_forward, &MyMotion.word_forward/2)
```

The BEAM's code server manages two versions of a module simultaneously. Old calls finish on the old code, new calls use the new version. This is safer than Elisp's immediate replacement, where redefining a function mid-execution can cause subtle bugs.

### 2. Advice system ✅

Emacs has eight advice combinators. Minga implements four that cover all the same use cases. The conditional combinators (`:before-while`, `:before-until`, `:after-while`, `:after-until`) rely on Elisp's nil/non-nil truthiness, which doesn't map to Elixir. Use `:around` instead; it gives you full control over whether the command runs.

| Emacs | Minga | Notes |
|-------|-------|-------|
| `:before` | `:before` | Transforms state before the command |
| `:after` | `:after` | Transforms state after the command |
| `:around` | `:around` | Receives original function; full control |
| `:override` | `:override` | Replaces the command entirely |
| `:before-while` | Use `:around` | `if condition, do: execute.(state), else: state` |
| `:before-until` | Use `:around` | Same pattern, inverted condition |
| `:after-while` | Use `:around` | Check result after calling `execute.(state)` |
| `:after-until` | Use `:around` | Same pattern, inverted condition |

**Elisp:**
```elisp
(define-advice save-buffer (:before (&rest _args))
  "Strip trailing whitespace before every save."
  (delete-trailing-whitespace))

;; :before-while — only save if buffer has a file
(advice-add 'save-buffer :before-while
  (lambda (&rest _) (buffer-file-name)))

;; :around — full control
(define-advice format-buffer (:around (orig-fn &rest args))
  "Skip formatting if buffer has errors."
  (if (zerop (length (flymake-diagnostics)))
      (apply orig-fn args)
    (message "Format skipped: buffer has errors")))
```

**Elixir:**
```elixir
# :before — transform state on the way in
advise :before, :save, fn state ->
  strip_trailing_whitespace(state)
end

# :around — conditionally skip formatting (replaces :before-while pattern)
advise :around, :format_buffer, fn execute, state ->
  errors =
    state.buffers.active
    |> Minga.Diagnostics.for_buffer()
    |> Enum.count(fn d -> d.severity == :error end)

  if errors == 0 do
    execute.(state)
  else
    %{state | status_msg: "Format skipped: #{errors} error(s)"}
  end
end

# :override — replace save with a version that also stages in git
advise :override, :save, fn state ->
  state = Minga.API.save()
  case Minga.Buffer.Server.file_path(state.buffers.active) do
    nil -> state
    path ->
      System.cmd("git", ["add", path], stderr_to_stdout: true)
      %{state | status_msg: "Saved and staged: #{Path.basename(path)}"}
  end
end
```

**Where Elixir is stronger:** Advice runs inside a supervised process. If your advice function raises an error, it's caught, logged, and skipped. The command still runs, the editor stays up. In Emacs, badly written advice can leave the editor in a half-modified state. Minga also stores advice in an ETS table with `read_concurrency`, so looking up advice adds zero contention to the command dispatch path, even under heavy programmatic editing (AI agents, macros).

### 3. Hooks ✅

**Elisp:**
```elisp
(add-hook 'after-save-hook #'my-post-save-function)
```

**Elixir:**
```elixir
on :after_save, fn buffer_pid, path ->
  if String.ends_with?(path, ".ex"), do: System.cmd("mix", ["format", path])
end
```

**Where Elixir is stronger:** Hooks run concurrently in their own processes. A slow hook never blocks your typing.

### 4. Buffer-local variables ✅

**Elisp:**
```elisp
;; Is this global or local? Depends on make-local-variable. Have fun.
(setq tab-width 4)         ;; global, unless someone called make-local-variable
(setq-local tab-width 2)   ;; local to current buffer
(setq-default tab-width 4) ;; sets the default for new buffers
```

In Emacs, whether `setq` writes a global or local depends on whether someone previously called `make-local-variable` on that symbol in the current buffer. This is invisible state that makes it hard to reason about what `setq` actually does.

**Minga:**
```elixir
# In command mode:
#   :set wrap          -> writes to THIS buffer
#   :setglobal wrap    -> writes to the global default (all buffers without a local override)

# In Elixir:
Buffer.Server.set_option(buffer_pid, :tab_width, 2)  # always buffer-local
Minga.Config.Options.set(:tab_width, 4)               # always global default
```

The scope is always explicit in the command you choose. `:set` is buffer-local, `:setglobal` is the global default. There is no `make-local-variable` equivalent because every buffer is a BEAM process with its own state. Buffer-local is the structural default, not a mode you opt into.

**Resolution chain:** When reading an option, Minga checks buffer-local first, then filetype defaults, then the global default. This maps to Emacs as:

| Emacs | Minga |
|-------|-------|
| `setq-local` | `:set` or `Buffer.Server.set_option/3` |
| `setq-default` | `:setglobal` or `Options.set/2` |
| `make-local-variable` | Not needed. Process isolation makes every option structurally local. |
| `kill-local-variable` | Not yet implemented. The buffer always has a value (from seeding). |

**Where Elixir is stronger:** No `make-local-variable` dance. Process boundaries enforce the separation. You cannot accidentally mutate another buffer's state. The VM prevents it. Options are eagerly seeded from filetype/global defaults when a buffer opens, so reading an option never crosses a process boundary.

### 5. Live evaluation ✅

**Elisp:**
```elisp
;; M-: evaluate any expression
(buffer-file-name)
```

**Elixir:**
```elixir
Buffer.Server.file_path(current_buffer())
Enum.map(buffers(), &Buffer.Server.file_path/1)
```

**Where Elixir is stronger:** You can inspect any process's live state, trace messages, and use `:observer.start()` for a full system dashboard. Emacs has nothing equivalent.

### 6. Introspection ✅

**Elisp:**
```elisp
(describe-function 'forward-word)
(describe-key (kbd "C-f"))
```

**Elixir:**
```elixir
h Minga.Motion.Word.word_forward      # docstring from @doc
Minga.Keymap.describe("SPC f f")      # binding lookup
Minga.Motion.Word.__info__(:functions) # list all functions
```

Documentation lives in `@moduledoc` / `@doc` attributes, always in sync with the running code because it *is* the running code.

### 7. The config IS the language ✅

**Elisp:** `init.el` is real Lisp. You program the editor.

**Elixir:** `config.exs` is real Elixir. You program the editor.

```elixir
use Minga.Config

set :theme, :doom_one
set :tab_size, 2

bind :normal, "SPC g s", :git_status, "Git status"

command :count_todos, "Count TODOs in buffer" do
  content = Buffer.Server.content(current_buffer())
  count = content |> String.split("\n") |> Enum.count(&String.contains?(&1, "TODO"))
  notify("#{count} TODOs found")
end

for_filetype :elixir do
  set :formatter, {"mix", ["format", "--stdin-filename", "{file}", "-"]}
  on :after_save, fn _buf, path -> System.cmd("mix", ["format", path]) end
end

require_config "modules/*.ex"
```

When you outgrow your config, you're already writing the same code as the editor itself. No graduation from "config language" to "real language." It's Elixir all the way down.

---

## The honest comparison

| Aspect | Elisp | Elixir |
|--------|-------|--------|
| **Execution model** | Single-threaded interpreter | Multi-process preemptive VM |
| **Function redefinition** | Immediate, per-function | Per-module reload (~50ms) |
| **Eval speed** | Interpreted (fast for small exprs) | Interpreted via `Code.eval_string` (comparable) |
| **Failure behavior** | Can leave editor in inconsistent state | Contained to one process; supervisor recovers |
| **Extension concurrency** | None (slow extension freezes editor) | Extensions are processes; can't block UI |
| **GC model** | Stop-the-world (tunable but painful) | Per-process (no global pauses) |
| **State model** | Global mutable state (footgun-prone) | Per-process state (isolated by default) |
| **Community packages** | MELPA (thousands of packages) | Hex (large ecosystem, not editor-specific yet) |
| **Learning curve** | Lisp syntax is polarizing | Ruby/Python-like; approachable |
| **Editor internals** | Elisp + C wall | Elixir all the way down |

The single real trade-off: you reload a whole module, not a single function. In practice, modules are small and reload is fast. You won't notice.

---

## What you'd miss (honestly)

| Emacs has | Minga status |
|-----------|-------------|
| `org-mode` | Not planned. Org is a universe unto itself. |
| `magit` | Git integration planned (#23), as supervised processes |
| LSP (`eglot` / `lsp-mode`) | Planned (#22). Each LSP client as its own process |
| Thousands of MELPA packages | Early. The extension system is being built (#14) |
| Splits / windows | Planned. Keybindings exist, implementation pending |
| `projectile` | ✅ Project detection, known projects, `SPC p` group. See [Projects](PROJECTS.md) |
| `dired` | File tree planned (#40) |
| Decades of community wisdom | Brand new. You'd be early. |
| Emacs Lisp (if you love Lisp) | Elixir. Optional LFE support planned (#3) for Lisp fans. |
| Major modes (filetype keymaps) | ✅ [Keymap scopes](KEYMAP-SCOPES.md) + `SPC m` filetype bindings. `keymap :elixir do ... end` in config. |
| Minor modes (toggleable keymaps) | Future ([#216](https://github.com/jsmestad/minga/issues/216)). See below for why this is less of a gap than it sounds. |

Minga is not trying to replace Emacs today. `org-mode` alone is a reason to keep Emacs around.

But for code editing, the thing you actually spend most of your time doing, Minga offers the same deep programmability with an architecture that eliminates the concurrency, isolation, and observability gaps you've been working around for years.

---

## "But what about minor modes?"

If you're a Doom Emacs user, you rely on minor modes constantly. `lsp-mode` adds code action keybindings. `flycheck-mode` adds error navigation. `evil-surround` adds surround operators. Each minor mode contributes its own keybindings that activate when the mode is enabled and disappear when it's not. Minga doesn't have this yet. Here's why it's less of a gap than you'd expect.

**Most of what minor modes do in Emacs, Minga handles differently.**

In Emacs, minor modes exist because packages need a way to contribute keybindings without stomping on each other in a single global keymap. The minor mode system is the coordination mechanism. But Minga's architecture already solves the underlying problems:

- **LSP keybindings** live under `SPC c` globally. They no-op gracefully if no language server is connected. No mode toggle needed; the command itself checks for an active server.
- **Git keybindings** live under `SPC g` globally. Same pattern: the commands check for a git repo.
- **Surround operations** are operators in operator-pending mode (`ds"`, `cs"'`, etc.), not a separate mode layer.
- **Error navigation** (`]d`, `[d`) is always available. It just does nothing if there are no diagnostics.

The Doom Emacs pattern of "always bind the key, let the command handle the empty case" works better in practice than toggling keybindings on and off. Users build muscle memory for `SPC c a` (code action) regardless of whether an LSP is active. The key always exists, the popup always shows it, and the command tells you if it can't do anything right now.

**Where minor modes actually matter: extensions that ship keybindings.**

The real gap shows up when third-party extensions want to contribute keybindings that should only exist while their feature is active. A debugger extension shouldn't pollute the global keymap with `SPC d` bindings when no debug session is running. An AI extension might want to add bindings only when an agent is active.

This is a genuine need, but it's a future need. Minga's extension ecosystem is early. The keymap architecture (trie-based, centralized lookup, per-mode storage) is designed so that keymap layers can be added on top without restructuring anything. Mode handlers already go through `Keymap.Active` for all lookups; adding a layer stack is an internal change to that module, not a rewrite. See [#216](https://github.com/jsmestad/minga/issues/216) for the planned design.

**The short version:** Minga doesn't need minor modes today because the use cases they solve in Emacs are handled by different patterns here (global bindings with graceful no-ops, filetype-scoped `SPC m` bindings, advice system). When extensions mature enough to need toggleable keymap layers, the architecture is ready for them.

---

## The bet

Emacs is the most programmable editor ever built. That's why you use it, despite the single-threaded freezes, the GC pauses, the package conflicts, and the C core you can't touch.

Minga keeps the programmability and fixes everything else:

- **Same depth of customization:** hooks, advice, live eval, buffer-local state, config-as-code
- **Structural isolation:** components can't interfere with each other. Process boundaries enforce it.
- **True concurrency:** hooks, agents, LSP, background work all run in parallel without blocking your typing
- **No GC pauses:** per-process garbage collection
- **No C wall:** editor logic is Elixir all the way down
- **Modal editing:** because your wrists deserve it

If you've ever wished Emacs had real concurrency, isolated components, or production-grade observability: Minga is building exactly that. Same philosophy. Better runtime.
