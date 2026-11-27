# Key reference

This page is for anyone using Minga who wants to know what a key does. It lists the keys in the build you can install today, grouped by where you are when you press them: in a file, in the agent view, in a list or picker, in a prompt or the composer, and in the terminal client. By the end you can find any command from the keyboard and know which keys answer in each place.

You do not have to memorise any of it. Press `SPC` and pause to see what comes next: a menu lists every key you can press from there, and it keeps narrowing as you type. `SPC h k` followed by any key tells you what that key does where you are, and `SPC h b` lists every binding.

## How to read this page

Keys are written the way Minga shows them. `SPC f f` means press Space, then `f`, then `f`, one after the other. `gg` and `]c` are also sequences. Modifiers use the Mac symbols: `⌃` is Control, `⌥` is Option (Alt), `⇧` is Shift and `⌘` is Command, so `⌃D` means hold Control and press `d`. `↩` is Enter and `esc` is Escape.

The tables describe the default Vim keys. Where the desktop shortcut profile (`set :editing_model, :cua` in your [configuration](CONFIGURATION.md)) uses different keys, the section says so.

**This page is what ships today.** The [design keymap](design/keys.md) lists where keys are going for v0.1.0, including keys that do not work yet. When the two differ, this page describes your build. The same pull request that ships a key updates this reference, so a key appears here only once it works.

To change a key, see [Keybindings](CONFIGURATION.md#keybindings). To learn why the same key can mean different things in different places, see [Keymap Scopes](KEYMAP-SCOPES.md).

## In a file

You are here when the cursor is in a file's text. Printable keys keep their Vim meaning: motions, operators, text objects, registers, marks and macros work as they do in Vim, so this section lists only what Minga adds on top.

### Leader keys

Press `SPC` in Normal mode. These sequences also work from the agent view, the file tree and the Git status list, whenever you are not typing text.

| Keys | Action |
|------|--------|
| `SPC SPC` | Find a file in the project |
| `SPC ,` | Switch buffer |
| `SPC /` | Search the project |
| `SPC :` | Run a command by name |
| `SPC ;` | Evaluate an Elixir expression |
| `SPC 1` to `SPC 9` | Go to tab 1 to 9 |

**Files (`SPC f`)**

| Keys | Action |
|------|--------|
| `SPC f f` | Find a file |
| `SPC f F` | Find a file and open it in the other window |
| `SPC f o` | Open a file on a remote machine |
| `SPC f s` | Save the file |
| `SPC f p` | Open your config file |

**Buffers (`SPC b`)**

| Keys | Action |
|------|--------|
| `SPC b b` | Switch buffer |
| `SPC b B` | Switch buffer, including hidden ones |
| `SPC b n` | Next buffer |
| `SPC b p` | Previous buffer |
| `SPC b N` | New buffer |
| `SPC b d` | Close the buffer |
| `SPC b X` | Close the buffer and drop unsaved changes |
| `SPC b D` | Close the other buffers |
| `SPC b K` | Close all buffers |
| `SPC b m` | Open `*Messages*`, the editor's log |
| `SPC b W` | Open the warnings log |
| `SPC b l` | Set the buffer's language |

**Windows (`SPC w`)**

| Keys | Action |
|------|--------|
| `SPC w h` | Move to the window on the left |
| `SPC w j` | Move to the window below |
| `SPC w k` | Move to the window above |
| `SPC w l` | Move to the window on the right |
| `SPC w v` | Split side by side |
| `SPC w s` | Split top and bottom |
| `SPC w d` | Close the window |

**Search (`SPC s`)**

| Keys | Action |
|------|--------|
| `SPC s p` | Search the project |
| `SPC s s` | Search in this buffer |
| `SPC s r` | Search and replace |
| `SPC s t` | Search TODO comments |
| `SPC s i` | Symbols in this file |
| `SPC s w` | Symbols in the workspace |
| `SPC s j` | Jump list |
| `SPC s u` | Edit timeline |

**Code (`SPC c`)**

| Keys | Action |
|------|--------|
| `SPC c a` | Code actions |
| `SPC c d` | Go to definition |
| `SPC c D` | Find references |
| `SPC c i` | Go to implementation |
| `SPC c t` | Go to type definition |
| `SPC c k` | Hover documentation |
| `SPC c r` | Rename the symbol |
| `SPC c f` | Format the buffer |
| `SPC c x` | List diagnostics |
| `SPC c h` | Call hierarchy, incoming |
| `SPC c H` | Call hierarchy, outgoing |
| `SPC c v` | Expand the selection to the enclosing syntax node |
| `SPC c V` | Shrink the selection |
| `SPC c l i` | Language server info |
| `SPC c l r` | Restart the language server |
| `SPC c l s` | Stop the language server |
| `SPC c l S` | Start the language server |
| `SPC c l I` | Manage language tools |

**Project (`SPC p`)**

| Keys | Action |
|------|--------|
| `SPC p f` | Find a file in the project |
| `SPC p p` | Switch project |
| `SPC p r` | Recent files in the project |
| `SPC p .` | Browse the project |
| `SPC p a` | Add a known project |
| `SPC p d` | Remove a known project |
| `SPC p i` | Rebuild the project file cache |
| `SPC p T` | Run the project's tests |
| `SPC p h` | The project home, `*home*` |

[Projects](PROJECTS.md) explains how Minga finds the project these keys act on.

**Open (`SPC o`)**

| Keys | Action |
|------|--------|
| `SPC o p` | Show or hide the file tree |
| `SPC o r` | Reveal this file in the file tree |
| `SPC o b` | Open the BEAM observatory |

**Minga (`SPC a`)**

| Keys | Action |
|------|--------|
| `SPC a a` | Open the [tasks drawer](#in-the-tasks-drawer), or close it when it has the keyboard |
| `SPC a v` | Open the agent view, or return from it to where you were |
| `SPC a i` | Inspect the latest batch of subagents beside its parent conversation |
| `SPC a n` | New task: type its goal and it starts beside what you are doing |
| `SPC a S n` | New, empty agent session in the conversation |
| `SPC a s` | Stop the agent's current turn; queued messages stay queued. It works from any buffer: with a file in front it stops the conversation shown last (the one the modeline speaks for), or the only one working. With several working and none shown last it stops nothing and says so. On macOS, `⌘.` does the same from a file too |
| `SPC a ?` | Ask about the current line or the selection, inline |
| `SPC a e` | Rewrite the selection, inline |
| `SPC a r` | Pending reviews |
| `SPC a p` | Publish or discard the agent's staged edits, in one prompt |
| `SPC a u` | Confirm rejection of all pending changes from the latest Minga task in this buffer. Your edits stay |
| `SPC a d` | Reject the exact Minga change named when your undo or redo was blocked |
| `SPC a y` | Keep the exact Minga change named when your undo or redo was blocked |
| `SPC a W` | Why is this line like this? |
| `SPC a A` | Code autobiography |
| `SPC a q q` | Focus `*minga-queue*` inside the conversation |
| `SPC a q f` | Queue the composer's text as a follow-up |
| `SPC a x b` | Attach this buffer to your next message |
| `SPC a x f` | Attach a project file |
| `SPC a x d` | Attach this file's diagnostics |
| `SPC a x l` | List the attachments on your draft |
| `SPC a S h` | Resume an earlier session |
| `SPC a S H` | Read retained messages |
| `SPC a S R` | Rename the session |
| `SPC a S m` | Pick the model |
| `SPC a S t` | Pick the thinking level |
| `SPC a S l` | Pick where the agent runs, on this machine or a remote one |
| `SPC a S k` | Inspect the conversation checklist |
| `SPC a S s` | Stop the session |

**In a subagent peek**

Click a **Started** row in the parent conversation to inspect that child. From the parent transcript, `Tab` cycles through visible Started rows and `↩` opens the selected one.

| Keys | Action |
|------|--------|
| `]]` / `[[` | Inspect the next or previous sibling without opening another pane |
| `za` | Fold or unfold the parent's brief |
| `i` | Write to this subagent |
| `↩` | Send from the child composer |
| `⌥↩` | Add a line to the child draft |
| `Esc` | Leave the child composer without discarding its draft |
| `q` | Close the peek and return focus to the parent conversation |

**Workspaces (`SPC TAB`)**

| Keys | Action |
|------|--------|
| `SPC TAB TAB` | Switch to the workspace you used last |
| `SPC TAB N` | Next workspace |
| `SPC TAB P` | Previous workspace |
| `SPC TAB A` | Next agent workspace |
| `SPC TAB m` | Go to the manual workspace |
| `SPC TAB l` | Pick a workspace from a list |
| `SPC TAB r` | Rename the workspace |
| `SPC TAB i` | Set the workspace icon |
| `SPC TAB D` | Close the workspace |

**Toggles (`SPC t`)**

| Keys | Action |
|------|--------|
| `SPC t l` | Cycle line number styles |
| `SPC t w` | Word wrap |
| `SPC t i` | Invisible characters |
| `SPC t p` | Bottom panel |

**Help (`SPC h`) and Quit (`SPC q`)**

| Keys | Action |
|------|--------|
| `SPC h k` | Describe the next key you press |
| `SPC h b` | List every binding |
| `SPC h c` | Describe a command |
| `SPC h f` | Describe a function |
| `SPC h v` | Describe an option |
| `SPC h a` | Search commands and options by word |
| `SPC h l` | Show your recent keystrokes |
| `SPC h r` | Reload your config |
| `SPC h t` | Pick a theme |
| `SPC h T` | Start the interactive tutorial |
| `SPC h e l` | List extensions |
| `SPC h e u` | Update all extensions |
| `SPC h e U` | Update one extension |
| `SPC q q` | Quit Minga |
| `SPC q n` | Start fresh: close the files the last session restored and go to the project home |
| `SPC q u` | List unsaved text kept after a crash, to recover or discard it |

**Filetype (`SPC m`)**

`SPC m` holds keys for the language of the current file. Elixir, Ruby, TypeScript, JavaScript, C, C++ and Swift files ship with these, and you can [add your own](CONFIGURATION.md#filetype-scoped-bindings-spc-m).

| Keys | Action |
|------|--------|
| `SPC m a` | Switch between a file and its test |
| `SPC m t t` | Run this file's tests |
| `SPC m t p` | Run the test at the cursor |
| `SPC m t a` | Run all tests |
| `SPC m t r` | Rerun the last test |
| `SPC m t o` | Show the test output |

**Git (`SPC g`)** is empty until you install the optional GitExtended extension, which fills it with the status list, staging, commits and branches. See [Optional extensions](CONFIGURATION.md#optional-extensions).

### Jumps, folds and code navigation

These work in Normal mode without the leader.

| Keys | Action |
|------|--------|
| `]e` / `[e` | Next / previous diagnostic |
| `]d` / `[d` | Next / previous Git change |
| `]c` / `[c` | Next / previous Git change (same as `]d` / `[d`) |
| `]h` / `[h` | Next / previous change Minga made |
| `]x` / `[x` | Next / previous merge conflict |
| `]f` / `[f` | Next / previous function |
| `]t` / `[t` | Next / previous class or module |
| `]a` / `[a` | Next / previous parameter |
| `]n` / `[n` | Next / previous sibling in the syntax tree |
| `⌥J` / `⌥K` | Same as `]n` / `[n` |
| `⌥H` / `⌥L` | Expand / shrink the selection, same as `SPC c v` / `SPC c V` |
| `gd` | Go to definition |
| `gr` | Find references |
| `gi` | Go to implementation |
| `gy` | Go to type definition |
| `g.` | Code actions |
| `gc` | Comment or uncomment, followed by a motion |
| `K` | Hover documentation |
| `gj` / `gk` | Down / up one line of the file when a long line is wrapped |
| `g0` / `g$` | Start / end of the line of the file when it is wrapped |
| `za` | Toggle the fold at the cursor |
| `zc` / `zo` | Close / open the fold |
| `zC` / `zO` | Close / open the fold and the folds inside it |
| `zM` / `zR` | Close / open every fold |
| `zz` / `zt` / `zb` | Scroll so the cursor is in the middle / at the top / at the bottom |
| `⌃O` / `⌃I` | Back / forward in the jump list |

### Any time

| Keys | Action |
|------|--------|
| `⌃S` or `⌘S` | Save the file, in any mode. `⌘S` needs the macOS app or a terminal that reports `⌘` |
| `⌃Q` | Close the tab. With desktop shortcuts, quit Minga |

### While the completion menu is open

The menu opens as you type in Insert mode.

| Keys | Action |
|------|--------|
| `⌃N` or Down | Next suggestion |
| `⌃P` or Up | Previous suggestion |
| `Tab` or `↩` | Accept the suggestion |
| `esc` | Close the menu |

### With desktop shortcuts

With `set :editing_model, :cua`, letters type text in a file at all times, as in a desktop text field. The leader is still there. Hold Space and press the next key, for example hold Space and press `f`, then press `f` again for Find file.

| macOS app | Terminal | Action |
|-----------|----------|--------|
| `⌘C` | `⌃C` | Copy |
| `⌘X` | | Cut |
| `⌘V` | `⌃V` | Paste |
| `⌘Z` | `⌃Z` | Undo |
| `⇧⌘Z` | `⌃Y` | Redo |
| `⌘A` | `⌃A` | Select all |
| `⌘S` | `⌃S` | Save |
| | `⌃P` | Run a command by name |

## In the agent view

You are here after `SPC a v`. The agent view shows your conversation with the agent, the files it changed, and the composer where you write to it. The conversation is for reading, so single letters are commands instead of text. Press `?` at any time for the keys that apply right now.

### Reading the conversation

These apply while the composer is not focused.

| Keys | Action |
|------|--------|
| `j` / `k` | Scroll down / up one line |
| `⌃D` / `⌃U` | Scroll down / up ten lines |
| `gg` / `G` | Go to the top / bottom |
| `/` | Search the conversation |
| `n` / `N` | Next / previous match |
| `zA` | Expand or collapse every tool call and thinking block |
| `]c` / `[c` | Next / previous code block |
| `]f` / `[f` | Next / previous file the agent changed |
| `]F` | Browse all the files the agent changed |
| `y` | Copy the code block at the cursor |
| `Y` | Copy the whole message at the cursor |
| `gf` | Open the code block at the cursor in an editor buffer |
| `ga` | Apply the code block at the cursor to its file |
| `gp` | Pin or unpin the message |
| `gd` | Go to definition |
| `gb` | Go back to the source line, after `SPC a W` brought you here |
| `i`, `a`, `A` or `↩` | Focus the composer |
| `s` | Switch session |
| `Tab` | Switch between the conversation and the changed-file view |
| `}` / `{` | Make the conversation wider / narrower |
| `=` | Reset the split |
| `⌘.` | Stop the agent's turn on macOS; the queue is kept (`SPC a s` everywhere) |
| `r` | Retry or set up a provider, when the agent failed to start |
| `?` | Show or hide Help |
| `q` | Return to where you were |
| `esc` | Close whatever is open on top (Help, search). With nothing open, return to where you were |

Leader keys work here too, and `:` opens the command line, so `:w`, `:qa` and `:agent-models` work from the conversation. While a leader sequence, the command line or a search is waiting for input, every key goes to it: `SPC h k` followed by `q` describes `q` and does not close the view, and `:x` never rejects a change.

When the composer shows **Continue**, press `↩` in the composer's Normal mode, press `⌘↩` on macOS, or click **Continue**. Minga resumes the interrupted request without sending the draft or taking the next queued message. In Vim Insert mode, plain Return still adds a new line.

Any other key does nothing. The conversation is not a file, so a stray key never edits, or moves focus to, the file behind it. The same holds with desktop shortcuts: an undo or paste key pressed here is ignored. On macOS, `⌘S`, `⌘Z`, `⌘X`, `⌘C` and `⌘V` are menu commands and act as they do everywhere else.

### In the queue

When Minga is working, `⌥↩` in the Vim composer adds a next-turn message. Leave the composer and press `SPC a q q`, or click **Queue** in the conversation header, to manage the waiting messages.

| Keys | Action |
|---|---|
| `j` / `k` or Down / Up | Move the selection without moving the composer |
| `dd` | Remove the selected message. It will not be sent |
| `p` / `P` | Put the most recently removed message after / before the selected message in its own queue. If that queue has no other messages, put it back at the end |
| `↩` | Move the selected message and its attachments into the local composer for editing. In a remote conversation, open its separate editor; the message stays queued |
| `q` | Leave the queue and restore its previous focus |
| `esc` | Cancel a partial key sequence without closing the queue |

Each row is one whole message. Removed messages stay out of the queue until you put them back. Minga keeps up to eight removed messages in memory and tells you when an older removal is gone for good. Removed messages do not survive closing Minga.

### In the changed-file view

Press `Tab` from the conversation to focus it.

| Keys | Action |
|------|--------|
| `j` / `k` | Scroll down / up one line |
| `⌃D` / `⌃U` | Scroll down / up ten lines |
| `gg` / `G` | Go to the top / bottom |
| `Tab` | Back to the conversation |
| `}` / `{` / `=` | Resize or reset the split |
| `q` or `esc` | Return to where you were |

### Reviewing a change

Choose **Review** on a changed file to inspect it. Agent writes record changes without selecting another file or moving you out of your draft. The timeline keeps the same space before and after the first write, so incoming files do not move Send or the Review controls.

For example, if you are reviewing `checkout.ex` when the agent changes `shipping.ex`, your selected file and reading position stay unchanged. If the agent changes `checkout.ex` again, the old review stays visible with a **Stale** label. Choose **Review latest** to load the new revision before accepting or rejecting changes. **Back to chat** resumes your draft, including its editing mode and selection.

![Native Agent draft after background edits](images/agent-background-draft.png)

![Native read-only Review awaiting an explicit refresh](images/agent-review-stale.png)

While the review has focus, these keys replace their reading meaning:

| Keys | Action |
|------|--------|
| `]c` / `[c` | Next / previous change |
| `y` | Accept this change (**Use Agent version**) |
| `x` | Reject this change (**Keep mine**) |
| `Y` | Accept all remaining changes |
| `X` | Reject all remaining changes |

When every change is accepted or rejected, the view returns to the plain file.

With desktop shortcuts the review uses modifier keys, so nothing you press while reviewing can be mistaken for typing. They apply only while the review has focus; with the composer focused, the same keys keep their composer meaning. Both columns work in the macOS app.

| macOS app | Terminal | Action |
|-----------|----------|--------|
| `⌥↓` | `⌥↓` | Next change |
| `⌥↑` | `⌥↑` | Previous change |
| `⌘↩` | `⌃↩` | Accept this change (**Use Agent version**) |
| `⌘⌫` | `⌃⌫` | Reject this change (**Keep mine**) |
| `⇧⌘↩` | `⌃⇧↩` | Accept all remaining changes |
| `⇧⌘⌫` | `⌃⇧⌫` | Reject all remaining changes |

Help (`?`) and the **Keep mine** and **Use Agent version** buttons always show the keys of your editing model.

If a staged agent edit overlaps your own changes, Review shows both versions. Choose **Keep mine** (`x`) or **Use Agent version** (`y`) for the selected conflict. Minga applies the combined result only after every conflict has a choice and the source revisions still match. If either source changes, **Review latest** reloads the conflict before you can choose again.

### Approving a tool

An approval can arrive while you are writing the next message. Keep typing: the composer keeps its focus, selection and text, and the approval card stays available without turning your draft into a decision.

Use the card's buttons directly, or leave the composer to use the keys. In Insert mode, press `esc` once for Normal mode, then again to leave the composer. With the composer unfocused:

| Keys | Action |
|------|--------|
| `y` or `↩` | Approve this call once |
| `a` | Trust this tool for the rest of the session |
| `t` | Trust this tool for the rest of the turn |
| `n` | Deny this call |
| `esc` | Defer: the request stays pending and answerable |

Trust applies to the named tool, not to every tool the agent might use. Turn trust ends before your next message. A key held with a modifier, such as `⌃A`, is never an approval decision.

Each card belongs to one request in one conversation. A stale or duplicate activation cannot approve a different request; Minga explains the refusal instead. When a request completes or expires, its card retires and can no longer grant trust. Entering plan mode, losing the provider, resetting the conversation or restoring another one also retires the card.

While a tool waits for a decision, the workspace shows **Awaiting approval**, and Stop remains available. Denied, Cancelled and Expired are separate outcomes, not tool errors. Stopping a tool that has already started may leave its outcome unknown: Minga keeps the output it captured and does not claim that Stop undid anything. The Stop button applies only to the turn shown in the workspace.

While Help is open, `esc` or `?` closes Help before anything else, and typing, Enter and paste cannot edit or send the draft underneath.

See [Agent tool approval](CONFIGURATION.md#agent-tool-approval) to choose which tools ask first.

### Answering a question

When the agent pauses to ask which output to keep, choose **Answer question**. Choose a listed answer, choose **Type an answer…** to enter your own, or select **Cancel question** to resume the turn without an answer. `esc` closes the picker without answering. Your composer draft stays separate.

If the question does not fit in one preview, choose **Next question page** or **Previous question page**. Paging changes only the preview, not the pending answer or the draft. Choose **Inspect choice** when a label is too long for the list, read its pages, then choose **Use choice**. **Back to question** returns without answering.

An answer gives the agent information, not permission. If the agent later needs approval for a tool, it asks separately. See [Remote Agents](REMOTE_AGENTS.md#answer-a-remote-agent-question) for what happens across a disconnect or restart.

### Publishing Approved Edits

Approving an edit lets the agent make it, but it does not write the file yet. An agent session you start from the editor works in an isolated copy of the project, so an approved edit is staged: the agent sees it, **Review files** lists it, and the file on disk and your open buffer still show the old text. You decide when staged edits land.

When the agent finishes a turn with staged edits, a notification says, for example, "1 agent-edited file is not on disk" and offers **Publish** and **Discard**. Click either one, or use the key below from a file or the agent view.

| Keys | Action |
|------|--------|
| `SPC a p` | Publish or discard agent edits, in one prompt |

Publish writes the staged files to disk and merges them into any open buffer, then the agent keeps working in a fresh staging area. The agent itself confirms it is between turns before anything is published or discarded; if it is still working, or its staging area cannot be renewed, nothing changes and Minga says why. If you changed the same lines yourself in the meantime, Minga keeps both versions and opens the conflict review instead of overwriting your work. Discard drops the staged edits and leaves disk and buffers untouched. Both wait until the agent turn finishes; while it runs, Minga says so and changes nothing.

Staged edits are never lost silently. Every ordinary way out stops and shows the same Publish and Discard choice: `:q` and `:wq` when they would close the last tab, `:qa`, `:wqa`, the quit confirmation prompt, and quitting the macOS app. `:wq` and `:wqa` still save your buffers first. The force and abort quits, `:q!` (when it would exit), `:qa!` and `:cq`, quit and discard staged agent edits on purpose. Quitting is never blocked when nothing is staged.

Staged edits also survive a crash or restart. If the editor restarts on its own (for example after the watchdog recovers a frozen editor), the staged edits are still running and come back to their workspace. If Minga itself exits without a publish or discard, such as after a crash, the next start for the same project restores them: `*Messages*` says how many files were restored, and the same Publish and Discard notification appears. Minga saves each staged edit together with the version of the file it was made against. If that file changed on disk while Minga was not running, `*Messages*` says so, and publishing merges the two or keeps the edit staged as a conflict; it never overwrites your change. A saved edit that cannot be restored is named in `*Messages*` as lost.

The saved copies are private to your user (`~/.local/share/minga/staged_drafts`, or under `$XDG_DATA_HOME`), and Minga deletes them when you publish or discard. [Buffer-Aware Agents](BUFFER-AWARE-AGENTS.md) explains how staging works underneath.

## In the tasks drawer

You are here after `SPC a a`, or after clicking the modeline's needs-you segment. The drawer at the bottom of the window lists every task Minga is working on, needs-you first, with subagents beneath the task that started them. A drawer that opens while a task needs you starts on that task, so its keys answer it at once. Nothing in the drawer takes typed text, so single letters act on the selected task, and leader keys still work.

| Keys | Action |
|------|--------|
| `j` / `k` or the arrows | Move between tasks |
| `y` | Approve the selected task's request once |
| `a` | Trust that tool for the rest of the session |
| `t` | Trust that tool for the rest of the turn |
| `n` | Deny the request |
| `=` | Show what the request would change; `]h` and `[h` step between changes |
| `c` | New task: type its goal in the "New task ›" prompt |
| `r` | Retry a waiting, failed or stopped task |
| `o` | Show the task's recent tool output; `↩` there opens the first `file:line` it names |
| `i` | Inspect the task: open its conversation |
| `x` | Stop the task's turn, after asking; `y` stops it, `n` keeps it running |
| `↩` | Open the task's conversation, or its pending reviews when it is done |
| `q` or `esc` | Step back from a diff or output view, then close the drawer |
| `⌃G` | Give the keyboard back to the window and keep the drawer on screen |

Click a row to select it and give the drawer the keyboard, or click an action on a row to run it on that task. A click on the drawer's empty space gives it the keyboard without moving the selection. An answer in the drawer and an answer in the conversation are the same answer: whichever comes second says "Already answered in Minga".

One drawer shows at a time. Opening the tasks drawer while `*Messages*` is open hides Messages, and the drawer's header says "Messages hidden · q returns"; `q` brings Messages back.

## In a list or picker

You are here when Minga shows rows to choose from: a picker with a query line, the file tree, or the Git status list.

### Pickers

Find file, project search, the buffer switcher and every other list with a query line. Typing always edits the query, so only these keys are commands:

| Keys | Action |
|------|--------|
| `⌃J` or Down | Next row |
| `⌃K` or Up | Previous row |
| Page Down / Page Up | Next / previous page |
| `↩` | Open the highlighted row |
| `Tab` | Complete the query |
| `⌃.` | Open a menu of actions for the highlighted row |
| `⌃V` | Open the highlighted buffer in a split (buffer switcher only) |
| `esc` | Close the picker |

### File tree

Open it with `SPC o p`. `j`, `k`, `gg`, `G`, `⌃D` and `⌃U` move as they do in a file.

| Keys | Action |
|------|--------|
| `↩` | Open the file, or expand or collapse the folder |
| `Tab` | Expand or collapse the folder |
| `l` / `h` | Expand / collapse the folder |
| `a` | New file |
| `A` | New folder |
| `R` | Rename |
| `d` | Delete |
| `y` | Copy the path |
| `c` / `m` | Mark to copy / to move |
| `p` | Paste the marked entry here |
| `H` | Show or hide hidden files |
| `r` | Refresh |
| `-` | Show the parent folder as the root |
| `.` | Show the selected folder as the root |
| `~` | Show the project as the root again |
| `/` | Filter the tree as you type. `↩` keeps the filter, `esc` clears it |
| `?` | Show or hide Help |
| `q` or `esc` | Close the file tree |

With desktop shortcuts, Up and Down move, Right and Left expand and collapse, `↩` opens and `esc` closes.

An empty folder lists its next steps, New file and New folder. `j` and `k` (or Up and Down) move between them, `↩` runs the highlighted one, and a click runs either.

### Git status list

This list comes with the optional GitExtended extension ([Optional extensions](CONFIGURATION.md#optional-extensions)). Without the extension there is nothing to open, and these keys do nothing.

| Keys | Action |
|------|--------|
| `j` / `k` | Next / previous file |
| `J` / `K` | Next / previous section |
| `Tab` | Collapse or expand the section |
| `s` | Stage the file, or unstage it if it is already staged |
| `u` | Unstage the file |
| `S` / `U` | Stage all / unstage all |
| `d` | Discard the file's changes. Asks first: `y` confirms, `n` cancels |
| `p` | Preview the diff |
| `o` | Open the file |
| `↩` | Open the file. On a clean tree, run the highlighted next step |
| `cc` | Start a commit |
| `cg` | Write a commit message with the agent |
| `f` | Fetch |
| `l` | Pull |
| `P` | Push |
| `r` | Pull, then retry a push that failed |
| `q` or `esc` | Close the list |

A clean tree lists its next steps instead of files: Push when commits wait to go up, Pull and Fetch. `j` and `k` move between them, `↩` runs the highlighted one, and a click runs any of them. With desktop shortcuts, `P`, `l` and `f` work too.

## In a prompt or the composer

You are here when a text field has focus. Letters type text, so commands use Enter, Escape, Tab and a few modifier keys.

### Prompts and the command line

A prompt is a one-line question at the bottom of the window, such as a new name for a file. The command line opens with `:`.

| Keys | Action |
|------|--------|
| `↩` | Run or confirm |
| `esc` | Cancel |
| `Tab` | Complete |
| `⌃J` / `⌃K` or Down / Up | Move through the completions, on the command line |

The usual line-editing keys work in prompts and in the picker's query line: `⌃A` and `⌃E` go to the start and end of the line, `⌃H` deletes a character, `⌃W` deletes the word before the cursor and `⌃U` deletes everything before it. `⌃K` deletes everything after the cursor in a prompt that has no list.

### The agent composer

The composer is where you write to the agent. `SPC a v` opens the conversation with the composer focused; from the conversation, focus it with `i`, `a` or `↩`. It is a small Vim buffer: you start in Insert mode, and `esc` takes you to Normal mode, where motions, operators and Visual mode edit your draft.

In Insert mode:

| Keys | Action |
|------|--------|
| `↩`, `⇧↩` or `⌃J` | Start a new line |
| `⌘↩` | Send the message. While the agent is working, it steers the running turn |
| `⌥↩` | While the agent is working, queue the message for after its turn. Otherwise send it |
| `⌘.` | Stop the agent's turn on macOS. The queue and your draft are kept |
| Up / Down | Move within the draft. At its first or last line, recall earlier messages |
| `⌃U`, `⌃W`, `⌃A`, `⌃E`, `⌃H`, `⌃K` | Edit the line, as in every prompt: `⌃U` deletes to the start of the line, `⌃W` the word before the cursor |
| `⌃C` | Go to Normal mode. While the agent is working, also stop its turn |
| `esc` | Go to Normal mode |
| `SPC` | Types a space while you are in Insert mode. Press `esc` first to use leader keys |

In Normal mode:

| Keys | Action |
|------|--------|
| `↩` or `⌘↩` | Send the message. While the agent is working, it steers the running turn |
| `⌘.` | Stop the agent's turn on macOS (`SPC a s` everywhere). The queue and your draft are kept |
| `q` | Record a macro, as in any buffer |
| `esc` | Leave the composer for the conversation, where `q` closes the view |
| `SPC a q f` | Queue the message for after the agent's turn |

Shift with an arrow key keeps its Vim meaning here and does not start a selection. To select, press `esc`, then `v`, and use Vim motions. With desktop shortcuts, `↩` sends, `⇧↩`, `⌥↩` and `⌃J` start a new line, Up and Down recall earlier messages, and `⌘.` stops Minga while it works (macOS). To edit one waiting message, open [the queue](#in-the-queue) and press `↩` on its row.

## In the terminal

You are here when you run Minga in a terminal instead of the macOS app. Every table above applies. Most terminals cannot send `⌘` and do not report every modified key, so a few keys change:

- **Use `⌃` where the macOS app uses `⌘`.** The desktop shortcut tables above list both columns. In the default Vim keys nothing needs `⌘`.
- **`⌘S` and `⌘Z` work where the terminal reports `⌘`.** With the Kitty keyboard protocol (Ghostty, kitty, WezTerm), `⌘S` saves in any mode and `⌘Z` undoes in Normal mode, unless the terminal keeps the key for itself. Everywhere else use `⌃S` and `u`.
- **Modified Enter and Backspace need a modern terminal.** `⌃↩`, `⌃⌫` and their Shift forms reach Minga only from a terminal that reports them (the Kitty keyboard protocol, as in Ghostty, kitty and WezTerm). Elsewhere they arrive as plain Enter and Backspace, which never accept or reject a change.
- **`⇧↩` depends on the terminal too.** `↩` in Insert mode and `⌃J` start a new line in the composer from any terminal. `⌘↩` and `⌘.` reach Minga only from a terminal that reports `⌘` (the Kitty keyboard protocol) and does not keep the key for itself. Everywhere else, send with `esc` and then `↩`, and stop with `SPC a s`.
- **`esc` then `↩` sends, also when you type it fast.** Without the Kitty keyboard protocol a terminal sends Esc and Alt as the same byte, so Minga reads an `esc` that arrives on its own as Esc and what follows as a separate key. Inside tmux older than 3.5, set `escape-time` to 10 so tmux does not join the two keys into `⌥↩` itself.
- **Long Help scrolls with the keyboard.** In the agent view's Help, Up, Down, Page Up, Page Down, Home and End scroll, and so does the mouse wheel.
- **Leader keys with desktop shortcuts.** A terminal cannot tell that Space is held, so press Space and then the leader key quickly. Minga removes the space it typed.

Minga does not ship a built-in terminal pane yet. The keys planned for one are in the [design keymap](design/keys.md).

## Keeping this page honest

A key belongs on this page only when it works in the build you can install. The [design keymap](design/keys.md) is the plan: it lists where keys are going, and some of its rows are not built. The same pull request that ships a key, moves one or removes one updates this reference. If a key here does something else on your machine, that is a bug in Minga or in this page; please [report it](https://github.com/jsmestad/minga/issues).
