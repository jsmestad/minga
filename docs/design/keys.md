# Keys

Every key the Spine adds or changes, by context. The status column compares with today's keymap on `main`: **kept** means the binding exists and keeps its meaning, **changed** means the key exists but its meaning changes, **new** means the key is free today. Line references are to `lib/minga/keymap/defaults.ex` unless another file is named.

Notation: modifiers as Mac glyphs (⌃J, ⌥↩, ⌘.), leader sequences as `SPC a a`. Never `C-j`.

## Rules

- **One key, one meaning.** Within a context, a key does one thing on every row and every surface.
- **In a file, `y n = Y q` are always Vim.** Minga's changes are handled with leader keys, a text object and ex commands. Bare single-letter actions live only in Minga's special buffers.
- **Typing surfaces use control keys.** Where you type into a prompt (the switcher, filters), actions use ⌃ keys so letters stay text.
- **Bulk actions confirm.** Keep all and Reject all ask "y/n" in the minibuffer first.
- **Notices act through leader keys only.** An error notice in the echo area never takes bare keys; its actions are leader bindings such as `SPC c l r`, and `esc` dismisses it in Normal mode only.
- **`q` closes special buffers and splits; `esc` closes anything transient.** `q` in Minga's special buffers and splits (conversation, queue, subagent peek, checklist, attachments, retained history, the observatory) returns you to the window you came from, the way `quit-window` works in Emacs `special-mode` buffers and Doom popups. `esc` cancels or dismisses any transient surface (prompts, pickers, menus, overlays). In the conversation, `q` applies in Normal mode outside the composer, where it is not text.

## Leader

| Keys | Action | Status |
|---|---|---|
| `SPC SPC` | Find file in project | kept (122) |
| `:` | Commands; ⌘K is the macOS alias | kept (39) |
| `SPC ,` | Switch buffer and file switcher | new |
| `SPC b b` | Same switcher as `SPC ,` | kept (57) |
| `SPC 1` to `SPC 4` | Jump to pinned file 1 to 4 (⌘1 to ⌘4 on macOS) | changed (186 to 189, were tabs; tabs are gone) |
| `SPC c d` | Diagnostics list | kept (102) |
| `SPC g k` | Keep Minga's change at the cursor or in the selection | new |
| `SPC g r` | Reject Minga's change at the cursor or in the selection | new |
| `SPC g s` | Git status (a magit-style buffer) | new |
| `SPC g b` | Blame for the current line or file | new |
| `SPC t e` | Edit timeline | new |
| `SPC s q` | Quickfix group: open the list (`:copen`), with `:cdo` / `:cfdo` listed as hints in which-key | new |
| `SPC o t` | Toggle the terminal drawer | new |
| `SPC p h` | Project home (`*home*`) from anywhere | new |
| `SPC q n` | Start fresh instead of the restored session: closes the restored files and opens the project home | new |
| `SPC o T` | New terminal in the current window | new |

## Leader `SPC a` (Minga)

| Keys | Action | Status |
|---|---|---|
| `SPC a a` | Tasks drawer | changed (138, was "Toggle agent split") |
| `SPC a v` | Conversation split | kept (140) |
| `SPC a r` | Review buffer | kept (158, "Pending reviews") |
| `SPC a s` | Stop; ⌘. on macOS | kept (141) |
| `SPC a i` | Inspect a task or subagent in a split | new |
| `SPC a w` | Watch Minga: a split that follows Minga's edits and shows `*minga-shell*` | new |
| `SPC a p` | Publish edits | kept (159) |
| `SPC a f` | Queue follow-up | kept (165) |
| `SPC a q` | Dequeue to editor | kept (163) |
| `SPC a J` | Queued inputs buffer | kept (154) |
| `SPC a u` | Reject all of a task's changes, after "y/n" | kept key (166), now confirms |

`SPC a t` (139) is retired. It duplicated the old split toggle, and the split stays on `SPC a v`.

Minga is pre-release, so keys move without deprecation aliases.

## In a file

| Keys | Action | Status |
|---|---|---|
| `]h` / `[h` | Next / previous Minga change | new, replaces `]e` |
| `ih` / `ah` | Text object: one Minga change, inner or with context | new |
| `vah SPC g k` | Keep every change touched by the selection | new |
| `.` | Repeat the last keep or reject; counts work | new |
| `:'<,'>Minga keep` | Keep a range; `:%Minga reject` rejects a whole file | new |
| `]d` / `[d` | Next / previous diagnostic | kept (`normal_prefixes.ex:50`) |
| `]c` / `[c` | Next / previous git hunk | kept (`normal_prefixes.ex:51`) |
| `K` | Hover: diagnostic or docs | kept |
| `u`, ⌘Z | Undo your own edits only | changed behavior |

`]h` replaces `]e` ("next agent edit", `normal_prefixes.ex:56`) because it pairs with the `ih` / `ah` text object. `]e` / `[e` become free; no alias is kept.

## `*minga-review*`

| Keys | Action |
|---|---|
| `y` | Keep the change under the cursor |
| `n` | Reject it |
| `=` | Toggle the inline diff |
| `Y` | Keep all, after "Keep all 3 changes? y/n" |
| `]h` / `[h` | Next / previous change |
| `↩` | Jump to the change in its file |
| `q` | Close |

## `*minga-tasks*`

| Keys | Action | Rows |
|---|---|---|
| `j` / `k` | Move | all |
| `/` | Filter | all |
| `↩` | Open: the conversation, or the review for done rows | all |
| `y` `a` `t` `n` | Approve once, always for this session, this turn, deny | needs-you |
| `=` | Show the diff of the request | needs-you |
| `r` | Retry | waiting, failed |
| `o` | Output and log | all |
| `i` | Inspect in a split | all |
| `x` | Stop the task, after confirming | working |
| `q` | Close | all |

The approval keys match the agent scope today (`lib/minga/keymap/scope/agent.ex:249` to `252`: `y` or Enter approve once, `a` session, `t` turn, `n` or Esc deny).

## Task output (`o` on a task row)

| Keys | Action |
|---|---|
| `]]` / `[[` | Next / previous failure |
| `↩` on a `file:line` | Open the file at that line |
| `r` | Retry the task |
| `f` | Ask Minga to fix it, with the output attached |
| `q` | Close |

`]]` / `[[` mean "next block in a read-only log" here, as they do for command blocks in the terminal.

## Quit prompt

| Keys | Action |
|---|---|
| `s` | Save all and quit |
| `d` | Discard your unsaved edits and quit (Minga's unreviewed changes are kept) |
| `esc` | Cancel |

## Subagent peek

| Keys | Action |
|---|---|
| `]t` / `[t` | Next / previous sibling subagent, in this buffer only |
| `za` | Fold or unfold the Brief |
| `↩` | Open the full conversation |
| `q` | Close |

`]t` / `[t` are bound only inside the peek buffer. In normal mode `]t` keeps its meaning, "next class/module" (`normal_prefixes.ex:54`).

## File switcher (`SPC ,`)

| Keys | Action |
|---|---|
| `↩` | Open |
| `⌃V` | Open in a split |
| `⌃T` | Pin or unpin |
| `⌃J` / `⌃K` | Move |
| `esc` | Close |

## Quickfix (`SPC s q`)

| Keys | Action |
|---|---|
| `↩` | Jump to the item; the drawer stays open |
| `]q` / `[q` | Next / previous item, also after the drawer closes |
| `:cdo` / `:cfdo` | Run a command on every item or file (hints in which-key) |
| `q`, `esc` | Close |

## Bare keys in other special buffers

Special buffers (git status, the file tree, blame) follow the same rule as Minga's: single letters act there because they are not text.

| Buffer | Keys | Action |
|---|---|---|
| Git status | `l` | Git log |
| Git status | `q` | Close |
| File tree | `a` / `A` | New file / new folder (the dired convention) |
| File tree | `q` | Close |
| Blame (`SPC g b`) | `K` | Detail: commit, or Minga's task and review state |
| Blame | `↩` | On a Minga line, open that task's conversation; on a commit line, open the commit |
| Blame | `SPC g b`, `q` | Close |

## Composer

| Keys | Action |
|---|---|
| `↩` in Insert | Newline |
| `↩` in Normal, ⌘↩ | Send; steers while Minga works |
| `⌥↩` | Queue next message |
| `⌘.` | Stop (`SPC a s` in the terminal) |

## Built-in terminal

| Keys | Action |
|---|---|
| `⌃\ ⌃N` | Leave TERMINAL mode for Normal |
| `i`, `a`, `↩` on the prompt | Back to TERMINAL |
| `]]` / `[[` | Next / previous command block |
| `ic` / `ac` | Text object: a command's output / the whole block |
| `↩` on a failed block | Menu: `f` ask Minga to fix, `yic` copy output, `r` rerun, `q` send to quickfix |
| `↩` on a pending Minga command | Approval in the minibuffer: `y` once, `a` always, `t` this turn, `n` deny |
