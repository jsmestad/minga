# Agentic View Keymap

The agentic view (`SPC a t`) is a full-screen OpenCode-style interface for interacting with AI agents. It follows Doom Emacs conventions for read-only special buffers: vim navigation motions are preserved, editing keys are repurposed for contextual actions, and multi-key sequences use standard vim prefixes.

## Design Principles

1. **Sacred vim motions stay.** j/k, gg/G, Ctrl-d/u, /, n/N work exactly as a vim user expects.
2. **Editing keys are repurposed.** i/a focus the input (semantic parallel to "enter insert mode"). o toggles collapse (magit precedent). y copies (yank = copy). q closes (Doom special buffer convention).
3. **Standard prefixes for multi-key sequences.** `z` for folds, `]`/`[` for next/prev navigation, `g` for go-to actions.
4. **SPC leader always works.** In navigation mode, SPC delegates to the mode FSM so leader sequences and which-key popups function normally.

## Chat Navigation Mode

The default mode when the agentic view is open and the input is not focused.

### Scrolling

| Key | Action |
|-----|--------|
| `j` | Scroll down 1 line |
| `k` | Scroll up 1 line |
| `Ctrl-d` | Scroll down half page |
| `Ctrl-u` | Scroll up half page |
| `gg` | Scroll to top |
| `G` | Scroll to bottom |

### Fold / Collapse (z prefix)

| Key | Action |
|-----|--------|
| `za` | Toggle collapse at cursor (tool call or thinking block) |
| `zA` | Toggle ALL collapses |
| `zo` | Expand at cursor |
| `zc` | Collapse at cursor |
| `zM` | Collapse all |
| `zR` | Expand all |
| `o` | Toggle collapse at cursor (alias for `za`, magit precedent) |

### Bracket Navigation (]/[ prefix)

| Key | Action |
|-----|--------|
| `]m` / `[m` | Next / previous message |
| `]c` / `[c` | Next / previous code block |
| `]t` / `[t` | Next / previous tool call |

### Go-to (g prefix)

| Key | Action |
|-----|--------|
| `gg` | Go to top (standard vim) |
| `gf` | Open code block at cursor in editor buffer |

### Copy

| Key | Action |
|-----|--------|
| `y` | Copy code block at cursor to clipboard |
| `Y` | Copy full message at cursor to clipboard |

### Input

| Key | Action |
|-----|--------|
| `i` / `a` | Focus the input field |
| `Enter` | Focus the input field |

### Tool Approval

When a destructive tool is pending approval, these keys are intercepted:

| Key | Action |
|-----|--------|
| `y` / `Enter` | Approve the tool |
| `n` | Reject the tool |
| `a` | Approve this and all remaining tools in the turn |

See [Agent tool approval](CONFIGURATION.md#agent-tool-approval) for how to configure which tools require approval.

### Session

| Key | Action |
|-----|--------|
| `s` | Open session switcher |

### Panel Management

| Key | Action |
|-----|--------|
| `Tab` | Switch focus between chat and file viewer |
| `}` | Grow chat panel width (+5%) |
| `{` | Shrink chat panel width (-5%) |
| `=` | Reset panel split to default (65/35) |

### View

| Key | Action |
|-----|--------|
| `q` | Close agentic view |
| `Esc` | Close agentic view |
| `?` | Show help overlay |

### Search

| Key | Action |
|-----|--------|
| `/` | Search chat messages |
| `n` | Next search match |
| `N` | Previous search match |

### Leader (SPC)

| Key | Action |
|-----|--------|
| `SPC a n` | New agent session |
| `SPC a s` | Stop / abort agent |
| `SPC a m` | Pick agent model |
| `SPC a T` | Cycle thinking level |
| `SPC a t` | Toggle agentic view (close) |

## Chat Input Mode

Active when the input field is focused (after pressing `i`, `a`, or `Enter`).

| Key | Action |
|-----|--------|
| Printable chars | Type into input |
| `Enter` | Submit prompt |
| `Ctrl-c` | Submit (when text) / abort (when empty + streaming) |
| `Esc` | Unfocus input (return to navigation) |
| `Ctrl-d` | Scroll chat down half page |
| `Ctrl-u` | Scroll chat up half page |
| `SPC` | Types a space (not leader key) |

## File Viewer Navigation

Active when the file viewer panel has focus (after pressing `Tab`).

| Key | Action |
|-----|--------|
| `j` / `k` | Scroll down / up 1 line |
| `Ctrl-d` / `Ctrl-u` | Scroll half page |
| `gg` / `G` | Top / bottom |
| `Tab` | Switch focus back to chat |
| `q` / `Esc` | Close agentic view |
| `}` / `{` | Grow / shrink chat panel |
| `=` | Reset panel split |

All `z`, `]`/`[`, and `g` prefixes also work in the file viewer.

## Reserved Keys (not yet assigned)

These vim keys are reserved for their standard meanings and are not repurposed, even though they have no current function in the read-only agentic view:

- `h` / `l` (left/right movement)
- `w` / `b` / `e` / `W` / `B` / `E` (word motions)
- `f` / `F` / `t` / `T` (find/till char)
- `H` / `M` / `L` (screen top/middle/bottom)
- `d` / `c` / `x` / `r` / `R` (editing operators)
- `p` / `P` (paste)

## Doom Precedents

The key repurposing follows established Doom Emacs / Evil conventions for read-only special buffers:

- **magit:** `s` = stage, `o` = toggle section, `q` = close, `Tab` = toggle collapse
- **dired:** `d` = mark, `u` = unmark, `q` = close
- **org-agenda:** `q` = close, various single keys for mode-specific actions
- **which-key:** SPC leader popups work in all modes

The principle: in a read-only buffer, editing keys have no natural meaning, so they can be repurposed for contextual actions without violating user expectations.
