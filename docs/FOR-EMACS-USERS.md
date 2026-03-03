# Minga for Emacs Users

You love Emacs because you can modify *anything*. The advice system, hooks,
buffer-local variables, live eval. No other editor comes close to that
level of programmability. So why would you even look at something else?

**Because Emacs's greatest strength has a fatal flaw: no isolation.**

Every extension, every hook, every piece of advice runs in one shared
address space. A bad package corrupts your state. A slow hook freezes
your editor. An error in your `init.el` leaves you staring at a backtrace
instead of your code. You've accepted these trade-offs because nothing
else offered the same extensibility.

Minga does. And it fixes the trade-offs.

---

## What you keep

The extensibility model you love transfers directly. Minga's runtime
is the BEAM (the Erlang virtual machine) and Elixir is its Elisp.

| Emacs concept | Minga equivalent | Status |
|--------------|-----------------|--------|
| `defun` / `fset` (redefine anything) | Hot code reloading (swap modules at runtime) | ✅ |
| `define-advice` (wrap any function) | `advise :before/:after/:around` | Planned |
| `add-hook` (attach to events) | `on :after_save, :buffer_open, ...` | Planned |
| Buffer-local variables | Per-process state (isolation enforced by VM) | Planned |
| `M-:` / `eval-expression` | `Code.eval_string` / eval prompt | Planned |
| `describe-function` / `describe-key` | `h/1`, `:sys.get_state`, runtime docs | Planned |
| `init.el` is real Elisp | `config.exs` is real Elixir | Planned |
| MELPA packages | Hex packages + supervised extensions | Future |

Every property that makes Emacs Emacs, Minga is building on the BEAM.
The [Elixir as Elisp](#elixir-is-mingas-elisp) section below proves it
point by point.

---

## What's actually wrong with Emacs

You know these problems. You've just decided they're worth it. But they
don't have to be.

### 1. A bad package can destroy your session

You've been there. You update a package, restart Emacs, and your `init.el`
fails halfway through. You're dropped into a half-configured editor with
broken keybindings and missing modes. Or worse, a package runs fine for
weeks, then hits an edge case that corrupts a buffer's undo history or
leaves `after-save-hook` in a broken state.

Emacs has no isolation. Every package, every hook, every piece of advice
shares one Elisp environment. `magit` can accidentally shadow a variable
that `org-mode` depends on. A `use-package` `:config` block can throw an
error that prevents the rest of your init from loading.

**Minga:** Every component is an isolated BEAM process. Packages run in
their own supervised process trees. A crash in a git integration package
cannot affect your buffer state because they're in different processes with
different memory. The supervisor detects the crash and restarts the package.
You see an error message in the status bar. Your editing session continues.

### 2. One slow hook freezes everything

```elisp
(add-hook 'after-save-hook #'my-format-and-lint)
```

If `my-format-and-lint` takes 3 seconds, your editor freezes for 3 seconds.
Every save. You can't type, you can't scroll, you can't switch buffers.
Emacs is single-threaded. Your hooks, your commands, your rendering, all
on one thread.

You've tried workarounds. `async.el`. `emacs-async`. Shelling out with
`start-process`. They help, but they're brittle. Coordinating async results
back into the single-threaded Elisp environment is error-prone, and most
packages don't bother.

**Minga:** Hooks run in their own BEAM processes. The editor's main loop
never blocks:

```elixir
on :after_save, fn _buf, path ->
  # This takes 3 seconds. Your editor doesn't care.
  # It's running in a separate process.
  System.cmd("mix", ["format", path])
  System.cmd("mix", ["credo", "--strict", path])
end
```

This isn't async bolted on. The BEAM's preemptive scheduler runs all
processes concurrently with fairness guarantees. Your typing always gets
CPU time, even if a hook is doing heavy work.

### 3. GC pauses are real

Emacs uses a stop-the-world garbage collector. When it runs, everything
pauses: rendering, input handling, all of it. With large buffers or
many packages loaded, you've felt the stutters. `gc-cons-threshold`
tuning is a rite of passage for Emacs users. You shouldn't need to tune
your garbage collector to get a smooth editing experience.

**Minga:** Each BEAM process has its own heap and its own garbage collector.
When a large buffer's process collects garbage, it doesn't pause the editor,
the renderer, or any other buffer. A 10MB log file being GC'd has zero
impact on the small config file you're actively editing.

### 4. The C core is a wall

Emacs is "written in Elisp," except for the parts that aren't. The
display engine, the regex engine, buffer internals, the redisplay loop:
these are C. When you need to change how rendering works, or fix a display
bug, or modify buffer data structures, you hit a wall. The C core isn't
practically modifiable by users.

This creates two classes of functionality: things you can customize (Elisp
layer) and things you can't (C core). You've worked around C-level
limitations by writing increasingly clever Elisp, but the wall is always
there.

**Minga:** The editor logic is Elixir all the way down. Buffers, modes,
motions, operators, commands, the keymap trie, the renderer pipeline: it's
all Elixir modules you can read, understand, and replace at runtime. The
only C-level boundary is the Zig renderer, and that's on the other side of
a process boundary by design. It handles pixels, not editor logic.

### 5. AI agents in Emacs are terrifying

You're using `gptel` or `ellama` or `org-ai`. They make HTTP requests to
LLM APIs, stream responses into buffers, and sometimes execute code. All
of this happens in your single-threaded Elisp environment. A hung API call
blocks your editor. A malformed response can corrupt buffer state.

Now imagine agentic tools that don't just chat but modify files, run
shell commands, create buffers, and operate autonomously for minutes.
In Emacs, all of that runs in the same environment as your typing.
One bad agent operation and you're reaching for `kill -9`.

**Minga:** Each AI agent session is its own supervised process tree. It
communicates with buffers via message passing, the same mechanism the
editor itself uses. An agent can't corrupt buffer state because it doesn't
have direct access to buffer memory. An agent crash takes down the agent,
not your editor. You can run multiple agents on multiple buffers
simultaneously. The BEAM was built for exactly this kind of workload.

---

## What you gain

Beyond fixing Emacs's problems:

### Modal editing (yes, really)

You might already use `evil-mode`, an admission that Emacs's default
keybindings cause RSI and Vim's modal model is more efficient. Minga gives
you Vim-native modal editing without the impedance mismatch of running a
Vim emulation layer on top of a non-modal editor:

- Full normal/insert/visual/operator-pending modes
- `d`, `c`, `y` + motions and text objects (`iw`, `i"`, `a{`, etc.)
- Space-leader keys with Which-Key popup (like Doom's `SPC` menus)
- Macros, registers, marks, dot repeat

If you use Doom Emacs, the leader key layout will feel familiar.

### Hot code reloading that actually works

Emacs has `eval-buffer` and `load-file`. They work, but reloading a
package often requires restarting because of stale state, cached
closures, and order-dependent initialization.

The BEAM was designed for hot code upgrades in production systems. It
manages two versions of a module simultaneously. Old calls finish on the
old version, new calls use the new code. Reload your config with `SPC h r`
and the editor applies changes cleanly. No restart. No stale state.

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

This exists because the BEAM was built for systems that run 24/7 and must
be debuggable without stopping. You get telecom-grade introspection for
free.

---

## Elixir is Minga's Elisp

This is the part that matters most to Emacs users. You need proof that
Elixir can replace Elisp, not just for config, but for the deep
programmability that makes Emacs what it is.

Here's the point-by-point comparison across every property that makes
Elisp powerful:

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

The BEAM's code server manages two versions of a module simultaneously.
Old calls finish on the old code, new calls use the new version. This is
safer than Elisp's immediate replacement, where redefining a function
mid-execution can cause subtle bugs.

### 2. Advice system ✅

**Elisp:**
```elisp
(define-advice save-buffer (:before (&rest _args))
  "Strip trailing whitespace before every save."
  (delete-trailing-whitespace))
```

**Elixir:**
```elixir
advise :before, :save, fn state ->
  strip_trailing_whitespace(state)
end

advise :around, :format_buffer, fn original_fn, state ->
  if get_option(state, :auto_format), do: original_fn.(state), else: state
end
```

**Stronger than Elisp:** A crash in your advice kills that command
execution, not the editor. The supervisor recovers.

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

**Stronger than Elisp:** Hooks run concurrently in their own processes.
A slow hook never freezes your editor.

### 4. Buffer-local variables ✅

**Elisp:**
```elisp
;; Is this global or local? Depends on make-local-variable. Have fun.
(setq tab-width 4)
(setq-local tab-width 2)
```

**Elixir:**
```elixir
Buffer.Server.set_option(buffer_pid, :tab_size, 2)  # always local
Minga.Config.set(:tab_size, 4)                       # always global
```

**Stronger than Elisp:** No `make-local-variable` dance. Process boundaries
enforce the separation. You cannot accidentally mutate another buffer's
state. The VM prevents it.

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

**Stronger than Elisp:** You can inspect any process's live state, trace
messages, and use `:observer.start()` for a full system dashboard. Emacs
has nothing equivalent.

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

Documentation lives in `@moduledoc` / `@doc` attributes, always in sync
with the running code because it *is* the running code.

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

When you outgrow your config, you're already writing the same code as the
editor itself. No graduation from "config language" to "real language."
It's Elixir all the way down.

---

## The honest comparison

| Aspect | Elisp | Elixir |
|--------|-------|--------|
| **Execution model** | Single-threaded interpreter | Multi-process preemptive VM |
| **Function redefinition** | Immediate, per-function | Per-module reload (~50ms) |
| **Eval speed** | Interpreted (fast for small exprs) | Interpreted via `Code.eval_string` (comparable) |
| **Crash behavior** | Crashes Emacs or corrupts state | Crashes one process; supervisor restarts it |
| **Extension concurrency** | None (slow extension freezes editor) | Extensions are processes; can't block UI |
| **GC model** | Stop-the-world (tunable but painful) | Per-process (no global pauses) |
| **State model** | Global mutable state (footgun-prone) | Per-process state (isolated by default) |
| **Community packages** | MELPA (thousands of packages) | Hex (large ecosystem, not editor-specific yet) |
| **Learning curve** | Lisp syntax is polarizing | Ruby/Python-like; approachable |
| **Editor internals** | Elisp + C wall | Elixir all the way down |

The single real trade-off: you reload a whole module, not a single function.
In practice, modules are small and reload is fast. You won't notice.

---

## What you'd miss (honestly)

| Emacs has | Minga status |
|-----------|-------------|
| `org-mode` | Not planned. Org is a universe unto itself. |
| `magit` | Git integration planned (#23), as supervised processes |
| LSP (`eglot` / `lsp-mode`) | Planned (#22). Each LSP client as its own process |
| Thousands of MELPA packages | Early. The extension system is being built (#14) |
| Splits / windows | Planned. Keybindings exist, implementation pending |
| `dired` | File tree planned (#40) |
| Decades of community wisdom | Brand new. You'd be early. |
| Emacs Lisp (if you love Lisp) | Elixir. Optional LFE support planned (#3) for Lisp fans. |

Minga is not trying to replace Emacs today. `org-mode` alone is a reason
to keep Emacs around.

But for code editing, the thing you actually spend most of your time
doing, Minga offers the same deep programmability with an architecture
that eliminates the problems you've been working around for years.

---

## The bet

Emacs is the most programmable editor ever built. That's why you use it,
despite the single-threaded freezes, the GC pauses, the package conflicts,
and the C core you can't touch.

Minga keeps the programmability and fixes everything else:

- **Same depth of customization:** hooks, advice, live eval, buffer-local
  state, config-as-code
- **Crash isolation:** a bad extension crashes its process, not your editor
- **True concurrency:** hooks, agents, LSP, background work all run in
  parallel without blocking your typing
- **No GC pauses:** per-process garbage collection
- **No C wall:** editor logic is Elixir all the way down
- **Modal editing:** because your wrists deserve it

If you've ever wished Emacs had process isolation, concurrent hooks, or
per-process GC: Minga is building exactly that. Same philosophy. Better
runtime.
