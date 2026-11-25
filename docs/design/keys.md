# Keys

This page is the plan: where keys are going for v0.1.0, including keys that are not built yet. For what each key does in the build you can install today, read the [Key reference](../AGENTIC-KEYMAP.md).

Every key the Spine adds, changes or retires, by context. The status column compares with today's keymap on `main`: **kept** means the binding exists and keeps its meaning, **changed** means the key or its meaning changes, **new** means the key is free today, **retired** means the binding goes away. **shipped** marks a change or retirement that is in today's keymap; the rest of the row says what it replaced. Line references are to `lib/minga/keymap/defaults.ex` unless another file is named.

Notation: modifiers as Mac glyphs (⌃J, ⌥↩, ⌘.), leader sequences as `SPC a a`. Never `C-j`.

Minga is pre-release, so keys move without deprecation aliases.

## The key grammar

Keys are chords and mnemonics, not shortcuts. This is [principle 11](principles.md#11-keys-are-chords-and-mnemonics), and every binding follows it, in this order:

1. **Mnemonic leader sequences first.** `SPC`, then the which-key group letter, then the action letter. The groups are `a` Minga, `b` buffers, `c` code, `f` files, `g` git, `h` help, `o` open, `p` project, `q` quit and session, `s` search, `t` toggles, `w` windows.
2. **Vim grammar inside buffers.** Operators, motions, text objects, `]x` / `[x` pairs and the `g` prefix.
3. **Single mnemonic letters only in special buffers.** `y` yes or keep, `n` no or reject, `r` retry, `o` output, `q` quit, and so on, in buffers where letters are not text.
4. **Modifiers only where letters must type text,** and only from established conventions. The allow-list: `⌃J` / `⌃K` to move in a list, `⌃V` / `⌃T` / `⌃Q` in pickers (Telescope), `⌥↩` in the composer, `⌃\ ⌃N` to leave the terminal, `⌃.` for the act menu. Never a chord that collides with text editing: `⌃A`, `⌃E`, `⌃H`, `⌃W`, `⌃U`, `⌃K` (outside list movement).
5. **macOS platform keys only as aliases** of a binding that needs no modifier: ⌘S, ⌘Z, ⌘W, ⌘Q, ⌘., ⌘1 to ⌘4, ⌘[ and ⌘]. In the composer only, ⌘↩ sends, as `↩` does in the composer's Normal mode.
6. **Never** three-modifier chords, ⌃⌘ or ⌥⌘ combinations, or function keys.

**Doom first.** Where Doom Emacs has a binding, Minga matches it. Neovim and LazyVim conventions come second. A deliberate divergence is written down with its reason. The key-grammar test (`test/minga/keymap/grammar_test.exs`, with a baseline of today's violations that only ever shrinks) enforces all of this.

**The CUA profile.** With `:editing_model :cua`, an explicit list of desktop conventions (⌘C, ⌘V, ⌘X, ⌘Z, ⌃Z and the like) is exempt from rules 4 and 5; one meaning per key, the prompt rules and rule 6 still apply. See [ADR-0007](../adr/0007-cua-is-a-key-profile.md).

**Overlays are their own context.** A surface that rebinds keys over its scope while it has focus, such as a focused Diff Review, is a separate grammar context. A key it rebinds is not a second meaning underneath it, and its own chords are allowed only inside it. See [Diff Review](#diff-review).

## Rules

- **One key, one meaning.** Within a context, a key does one thing on every row and every surface.
- **In a file, `y n = Y q` are always Vim.** Minga's changes are handled with leader keys, a text object and ex commands. Bare single-letter actions live only in special buffers.
- **Live prompts move into the list.** While a prompt has focus (find file, project search, new task, rename, the command line), actions are rows you reach with `⌃J` / `⌃K` or the arrows and run with `↩`, or click. Typing always edits the query.
- **Bulk actions confirm.** Keep all and Reject all ask "y/n" in the minibuffer first.
- **Notices act through leader keys only.** An error notice in the echo area never takes bare keys; its actions are leader bindings such as `SPC c l r`, and `esc` dismisses it in Normal mode only.
- **`q` closes special buffers and splits; `esc` closes anything transient.** `q` in special buffers and splits (conversation, queue, subagent peek, checklist, attachments, retained history, the observatory) returns you to the window you came from, the way `quit-window` works in Emacs `special-mode` buffers and Doom popups. `esc` cancels or dismisses any transient surface (prompts, pickers, menus, overlays). In the conversation, `q` applies in Normal mode outside the composer, where it is not text.
- **Groups read like leaves.** In which-key a group is written in Title Case like an action, in the group colour, with a trailing `›` and an optional dim count ("Session › 7"). Group labels never start with `+`. See [surfaces](surfaces.md#which-key).

## Leader

| Keys | Action | Status |
|---|---|---|
| `SPC SPC` | Find file in project | kept (122) |
| `:` | Commands; ⌘K is the macOS alias | kept (39) |
| `SPC ,` | Switch buffer and file switcher | shipped as the buffer switcher (an alias of `SPC b b`); files join it with the switcher work |
| `SPC b b` | Same switcher as `SPC ,` | kept (57) |
| `SPC 1` to `SPC 4` | Jump to pinned file 1 to 4 (⌘1 to ⌘4 on macOS). Diverges from Doom's workspaces on `SPC 1` to `SPC 9`; which-key labels them "Pinned" | changed (186 to 189, were tabs; tabs are gone) |
| `SPC ;` | Eval | shipped; replaces ⌥: (331), which is gone |
| `SPC c x` | Diagnostics list (Doom) | shipped; was `SPC c d` (102) |
| `SPC c d` | Go to definition (Doom) | shipped; was the diagnostics list (102) |
| `SPC c g` | (retired) | shipped, retired (105); `SPC c d` is definition |
| `SPC c D` | Find references | kept (103) |
| `SPC c v` / `SPC c V` | Expand / shrink the selection by syntax node | kept |
| `SPC g g` | Git status, a magit-style buffer (Doom) | new; replaces the proposed `SPC g s`. The git extension owns `SPC g` and binds this today |
| `SPC g s` | Stage hunk (Doom), reserved for the git group | new |
| `SPC g B` | Blame for the current line or file (Doom) | new; replaces the proposed `SPC g b`. The git extension owns `SPC g`; it still binds blame on `SPC g b` |
| `SPC g b` | Switch branch (Doom), reserved for the git group | new |
| `SPC g w` / `SPC g a` | (moved to `SPC a`) | shipped, retired (203, 204) |
| `SPC s u` | Edit timeline, the undo history including Minga's steps (Doom) | shipped; opens today's timeline of Minga's edits; your own steps do not join it yet |
| `SPC s i` | Document symbols (Doom imenu) | shipped; was `SPC s j` (46) and `SPC c j` (107) |
| `SPC s j` | Jump list (Doom) | shipped; was document symbols (46) |
| `SPC c j` | (retired; duplicate of document symbols) | shipped, retired (107) |
| `SPC s q` | Quickfix group: open the list (`:copen`), with `:cdo` / `:cfdo` listed as hints in which-key | new |
| `SPC h a` | Apropos (Doom): commands and options in one search | shipped; was a duplicate of `SPC h c` (86) |
| `SPC o t` | Toggle the terminal drawer (Doom) | new |
| `SPC o T` | New terminal in the current window (Doom) | new |
| `SPC p h` | Project home (`*home*`) from anywhere | shipped |
| `SPC q n` | Start fresh instead of the restored session: closes the restored files and opens the project home | shipped |
| `SPC q u` | Unsaved text: list the text kept after a crash that no start recovered, to recover or discard it | shipped (#4257) |
| `SPC f o` | Open a remote file | shipped; was `SPC a o` (161) |
| `SPC b P`, `SPC b <`, `SPC b >` | (tabs are gone) | shipped, retired (69, 70, 71) |
| `SPC b D`, `SPC b K` | Close other buffers / close all buffers | shipped (63, 64; were described as tabs) |
| `SPC TAB n`, `SPC TAB p`, `SPC TAB a`, `SPC TAB d` | (tabs are gone) | shipped, retired (169 to 172) |

## Leader `SPC a` (Minga)

A dozen everyday keys at the top; the rest live in three groups.

```
SPC a  Minga
  a  Tasks            v  Conversation      r  Review
  n  New task         i  Inspect           w  Watch
  s  Stop             y  Keep change       d  Reject change
  u  Reject all…      ?  Ask about this    e  Rewrite selection
  W  Why this line    A  Code autobiography
  p  Publish edits…
  q  Queue ›          x  Context ›         S  Session ›
```

| Keys | Action | Status |
|---|---|---|
| `SPC a a` | Tasks drawer | shipped (138, was "Toggle agent split") |
| `SPC a n` | New task (the minibuffer prompt) | shipped (143, was "New local agent session"; that is now `SPC a S n`) |
| `SPC a s` | Stop; ⌘. on macOS | kept (141) |
| `SPC a u` | Reject all of a task's changes, after "y/n" | kept key (166), now confirms |
| `SPC a v` | Conversation split | kept (140) |
| `SPC a i` | Inspect a task or subagent in a split | new |
| `SPC a y` | Keep Minga's change at the cursor or in the selection | new; replaces the proposed `SPC g k` |
| `SPC a d` | Reject Minga's change at the cursor or in the selection | new; replaces the proposed `SPC g r`; mirrors `y` / `n` in review |
| `SPC a ?` | Ask about the line or selection | kept (145) |
| `SPC a r` | Review buffer | kept (158, "Pending reviews") |
| `SPC a w` | Watch Minga: a split that follows Minga's edits and shows `*minga-shell*` | new |
| `SPC a e` | Rewrite selection inline | kept (146) |
| `SPC a W` | Why is this line like this? | shipped; was `SPC g w` (203) |
| `SPC a A` | Code autobiography | shipped; was `SPC g a` (204) |
| `SPC a p` | Publish edits: one prompt that offers publish or discard | shipped (159); absorbs `SPC a P` |
| `SPC a P` | (folded into `SPC a p`) | shipped, retired (160) |
| `SPC a t` | (duplicated the split toggle) | shipped, retired (139) |
| `SPC a c` | (copy file to workspace; workspaces are gone) | shipped, retired (148) |
| `SPC a Q` | (answer a question; answered from the tasks drawer row) | shipped, retired (164) |
| `SPC a o` | (moved to `SPC f o`) | shipped, retired (161) |

**What `SPC a s` stops.** One turn, never several, from any buffer:

1. the conversation in front;
2. with a file in front, the conversation shown last, which is the one the file's modeline speaks for;
3. otherwise the only conversation that is working.

With several conversations working and none of them shown last, Stop stops nothing and says so in one line. A specific task is stopped from its row in the tasks drawer (`x`). With a conversation in front, Stop acts on that conversation only, so it does nothing while that conversation is not working. With nothing working, Stop does nothing and says nothing.

The modeline answers a stop of the conversation it speaks for: it reads "Minga stopped". When Stop ends another conversation (rule 3, with a different conversation or none shown last), nothing in view changes, so the echo area names what was stopped by its goal: "Stopped: Write the report".

**`SPC a q` Queue ›**

| Keys | Action | Status |
|---|---|---|
| `SPC a q q` | Open the queue buffer (`*minga-queue*`); dequeue, reorder and delete live inside it | shipped; was `SPC a J` (154) and dequeue `SPC a q` (163); opens today's queued-inputs list |
| `SPC a q f` | Queue the composer input as a follow-up (`⌥↩` in the composer does the same) | shipped; was `SPC a f` (165) |

**`SPC a x` Context ›**

| Keys | Action | Status |
|---|---|---|
| `SPC a x b` | Attach this buffer | shipped; was `SPC a b` (155) |
| `SPC a x f` | Attach a project file | shipped; was `SPC a F` (156) |
| `SPC a x d` | Attach this file's diagnostics | shipped; was `SPC a D` (157) |
| `SPC a x l` | List draft attachments | shipped; was `SPC a j` (153) |

**`SPC a S` Session ›**

| Keys | Action | Status |
|---|---|---|
| `SPC a S n` | Start a new, empty session in the conversation | shipped; was `SPC a n` (143), which is now New task |
| `SPC a S h` | Resume a session | shipped; was `SPC a h` (149) |
| `SPC a S R` | Rename the session | shipped; was `SPC a R` (150) |
| `SPC a S m` | Pick the model | shipped; was `SPC a m` (147) |
| `SPC a S t` | Pick the thinking level | shipped; was `SPC a T` (162) |
| `SPC a S l` | Pick where the session runs | shipped; was `SPC a N` (144) |
| `SPC a S H` | Read retained messages | shipped; was `SPC a H` (151) |
| `SPC a S k` | Inspect the checklist | shipped; was `SPC a k` (152) |
| `SPC a S s` | Stop the session | shipped; was `SPC a S` (142) |

## In a file

| Keys | Action | Status |
|---|---|---|
| `]h` / `[h` | Next / previous Minga change | shipped; replaces `]e` / `[e` for agent edits and steps today's agent edit timeline until #4050 lands per-change navigation |
| `ih` / `ah` | Text object: one Minga change, inner or with context | new |
| `vah SPC a y` | Keep every change touched by the selection | new |
| `.` | Repeat the last keep or reject; counts work | new |
| `:'<,'>Minga keep` | Keep a range; `:%Minga reject` rejects a whole file | new |
| `]e` / `[e` | Next / previous diagnostic (Doom next-error) | shipped; was `]d` / `[d` |
| `]d` / `[d` | Next / previous git hunk (Doom diff-hl) | shipped; git hunks were on `]c` / `[c` |
| `]c` / `[c` | Next / previous change in a diff view | kept for diff buffers |
| `]n` / `[n` | Next / previous syntax node (sibling); `SPC c v` / `SPC c V` expand and shrink | shipped; ⌥j / ⌥k alias `]n` / `[n` and ⌥h / ⌥l alias `SPC c v` / `SPC c V`, which use the language server's selection ranges and fall back to the syntax tree without one |
| `g.` | Act menu on whatever is under the cursor | changed (`normal_prefixes.ex:27`, was "Code actions"); code actions are part of the act menu |
| `K` | Hover; `K` again focuses it | kept |
| `⌃O` / `⌃I` | Back / forward in the jump list (⌘[ / ⌘] on macOS; Tab is ⌃I, as in Vim) | shipped; replaces the proposed ⌃⌘← / ⌃⌘→ |
| `u`, ⌘Z | Undo your own edits only | shipped (#4048); Minga's edits never enter your undo, and an undo that would cross text Minga later rewrote does nothing |
| `gt` / `gT` | (tabs are gone) | shipped, retired |

`SPC .` stays Doom's "find file in this directory"; the act menu lives on `g.` in Normal mode and `⌃.` wherever you type.

## Act menu

| Keys | Action |
|---|---|
| `g.` | Open on the thing under the cursor (Normal mode, special buffers) |
| `⌃.` | Open from Insert mode, the composer, the terminal and pickers |
| Right-click | Open on the thing under the pointer |
| Letter on the left of a row | Run it from inside the menu |
| Typing | Filter |
| `↩` | Run the preselected (most likely) action |
| `esc` | Close |

Each row shows two keys: the letter that works inside the menu, and on the right the key that runs the action without the menu.

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
| `c` | New task (create, as in magit) | all |
| `y` `a` `t` `n` | Approve once, always for this session, this turn, deny | needs-you |
| `=` | Show the diff of the request | needs-you |
| `r` | Retry | waiting, failed |
| `o` | Output and log | all |
| `i` | Inspect in a split | all |
| `x` | Stop the task, after confirming | working |
| `q` | Close | all |

`n` means deny on a needs-you row, so a new task is `c`. The approval keys are the same in the conversation (`MingaEditor.Input.ToolApproval`): `y` or Enter approve once, `a` session, `t` turn, `n` deny. `esc` at any approval defers: the request stays pending and answerable from the conversation and the drawer.

## Task output (`o` on a task row)

| Keys | Action |
|---|---|
| `]]` / `[[` | Next / previous failure |
| `↩` on a `file:line` | Open the file at that line |
| `r` | Retry the task |
| `f` | Ask Minga to fix it, with the output attached |
| `q` | Close |

`]]` / `[[` mean "next block in a read-only buffer" here, as they do for command blocks in the terminal and siblings in the subagent peek.

## Quit prompt

| Keys | Action |
|---|---|
| `s` | Save all and quit |
| `d` | Discard your unsaved edits and quit (Minga's unreviewed changes are kept) |
| `esc` | Cancel |

## Subagent peek

| Keys | Action | Status |
|---|---|---|
| `]]` / `[[` | Next / previous sibling subagent | changed; replaces the proposed `]t` / `[t`, which keep "next class/module" (`normal_prefixes.ex:54`) |
| `za` | Fold or unfold the Brief | |
| `↩` | Open the full conversation | |
| `q` | Close | |

## Live prompts

Every picker (find file, project search, the switcher) and every minibuffer prompt (new task, rename, the command line) shares these keys. They live in the `:picker` and `:prompt` keymap scopes (`lib/minga/keymap/prompt_keys.ex`), so which-key, user overrides and the grammar test see them. Typing always edits the query.

| Keys | Action | Status |
|---|---|---|
| `⌃J` / `⌃K`, `↓` / `↑` | Move through the list | shipped; `⌃N` / `⌃P` retired |
| `↩` | Run the highlighted row, or submit the prompt | kept |
| `esc` | Close | kept; `⌃G` retired |
| `Tab` | Complete | kept |
| `PageDown` / `PageUp` | Page through a picker | shipped; replaces `⌃V` / `⌥V` |
| `⌃V` | Open the highlighted buffer in a vertical split (the switcher; file pickers follow when files stop opening tabs, #4063) | shipped; was page down |
| `⌃.` | Act menu on the highlighted row | shipped; replaces `⌃O` |
| `⌃D` | (delete moves into the act menu) | retired |
| `⌃A` `⌃E` `⌃H` `⌃W` `⌃U` | Line start, line end, delete a character, delete a word, delete to the start | shipped; text editing, never bindings |
| `⌃K` | Move up where there is a list; delete to the end of the line in a prompt without one | shipped |
| `⌃T`, `⌃Q` | Pin, send to quickfix (below) | new; arrive with pins and quickfix |

When nothing matches, the picker says so and offers its next steps as rows in the list (see [surfaces.md](surfaces.md#empty-states-and-notices-with-actions)): move to one with `⌃J` / `⌃K` and run it with `↩`, or click it. Typing keeps editing the query. A picker with nothing to filter at all (no projects yet, no extensions installed) takes no text, so it is a list like a special buffer: `j` / `k` move, `↩` runs, `q` or `esc` closes.

## File switcher

`SPC ,` opens the switcher.

| Keys | Action |
|---|---|
| `↩` | Open; on a query with no match, the first row offers to create the file |
| `⌃V` | Open in a split |
| `⌃T` | Pin or unpin |
| `⌃J` / `⌃K` | Move |
| `⌃.` | Act menu on the highlighted row: open all matches, export to a buffer, and more |
| `esc` | Close |

`Tab` only completes. There is no marking; bulk work uses "Open all N matches" or "Export to a buffer" from the act menu, then Vim selection in that buffer.

## Project search (`SPC s p`)

| Keys | Action |
|---|---|
| Typing | Edits the query; ripgrep flags go after `--` (`limit_lable -- -uu`), as in Doom's consult-ripgrep |
| `⌃J` / `⌃K` | Move through results, or through the next-step rows when nothing matches |
| `↩` | Open the result, or run the next-step row ("Search ignored files too  -- -u") |
| `⌃Q` | Send the results to quickfix |
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
| Blame (`SPC g B`) | `K` | Detail: commit, or Minga's task and review state |
| Blame | `↩` | On a Minga line, open that task's conversation; on a commit line, open the commit |
| Blame | `SPC g B`, `q` | Close |

## Composer

The composer is a buffer with Vim editing that opens in Insert when `SPC a v` opens the conversation.

| Keys | Action | Status |
|---|---|---|
| `↩` in Insert | Newline | shipped (#4055); was send |
| `↩` in Normal, ⌘↩ | Send; steers while Minga works | shipped (#4055) |
| `⌥↩` in Insert | Queue next message (`SPC a q f` from Normal) | shipped (#4055); was ⌃↩ |
| `⌘.` | Stop; the queue is kept (`SPC a s` in the terminal) | shipped (#4055) |
| `esc` in Normal | Leave the composer for the conversation, where `q` closes the split | kept |
| `q` in Normal | Vim's macro key, as in any buffer | changed (#4055); was "leave the composer" |
| `⌃U`, `⌃W` and the other readline keys in Insert | Edit the line, as in every prompt | shipped (#4055) |
| ⌥↑ | (dequeue moves into the queue buffer) | retired (#4055) |
| `⌃D` / `⌃U` while typing | (`⌃U` deletes to line start; scroll from Normal mode) | retired (#4055) |
| `⌃L` / `⌃S` / `⌃Q` | (clear, save and close live on `SPC a n`, `SPC f s` and `SPC a v` or `q`) | retired (#4055) |

## Diff Review

While a staged Diff Review has focus in the Agent view, its keys replace the Agent keys underneath. The review is its own grammar context: `y` keeps a hunk there and still copies a code block everywhere else, and one meaning per key holds inside the review and underneath it separately.

| Keys (Vim) | Keys (CUA) | Action |
|---|---|---|
| `]c` / `[c` | `⌥↓` / `⌥↑` | Next / previous hunk |
| `y` | `⌘↩`, `⌃↩` | Keep the hunk (on a fork conflict: use the Agent version) |
| `x` | `⌘⌫`, `⌃⌫` | Reject the hunk (on a fork conflict: keep mine) |
| `Y` | `⇧⌘↩`, `⌃⇧↩` | Keep every hunk |
| `X` | `⇧⌘⌫`, `⌃⇧⌫` | Reject every hunk |

The CUA chords are an allow-list for the review only, each tied to its exact command; they are not CUA conventions anywhere else. ⌘↩ keeps and ⌘⌫ undoes a change in Cursor and in VS Code agent edits, so CUA users already know them, and ⇧ widens either to every hunk. A terminal cannot send ⌘, so each ⌘ chord has a ⌃ twin. ⌥↓ and ⌥↑ step through hunks without typing text. Rule 6 still applies, which is why F7 is not bound. The allow-list lives in `test/support/key_grammar.ex` with the guard's other allow-lists; see [ADR-0007](../adr/0007-cua-is-a-key-profile.md#amendment-diff-review-chords-2026-11-24).

## Built-in terminal

| Keys | Action |
|---|---|
| `⌃\ ⌃N` | Leave TERMINAL mode for Normal |
| `i`, `a`, `↩` on the prompt | Back to TERMINAL |
| `]]` / `[[` | Next / previous command block |
| `ic` / `ac` | Text object: a command's output / the whole block |
| `↩` on a failed block | Menu: `f` ask Minga to fix, `yic` copy output, `r` rerun, `Q` send to quickfix (`q` always closes) |
| `↩` on a pending Minga command | Approval in the minibuffer: `y` once, `a` always, `t` this turn, `n` deny |
