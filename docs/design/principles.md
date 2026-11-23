# Principles

Ten rules. When a mockup, a review comment or a convenient shortcut disagrees with one of them, the rule wins or the rule changes through an ADR.

## 1. The text is the interface

Chrome speaks only when state changes, and then in words. The resting screen is your code, a plain title bar and one modeline. If an element is on screen all the time, it has to earn that by carrying state you need to see without asking.

## 2. One owner per fact

Every fact has one owner and one value. Minga's state is one BEAM value; the modeline, the tasks drawer, the subagent peek, notifications and both frontends render that value with the same words, shapes and colours. A frontend may decide how to draw a token. It may not invent a colour, a glyph, a label or an order.

## 3. Every key has a click, and every click teaches its key

Mouse is first-class: every action reachable by a key is reachable by a click, and the reverse. Shortcuts appear as plain glyphs in menus, tooltips and transient surfaces, never as boxed keycaps.

## 4. Context, not toggles

What keys do is derived from what is on screen and under the cursor, not from a mode you have to remember to leave. In a file, Vim keys are Vim keys. In Minga's special buffers (`*minga-tasks*`, `*minga-review*`), single letters act on the item under the cursor, the way magit and fugitive work.

## 5. Undo is yours; Reject is for Minga

`u` and ⌘Z undo only your own edits, like a collaborative editor. Minga's edits never disappear from under you because you pressed `u`. They leave through Reject, and each Minga edit step is its own undo group in Minga's history, so rejecting part of a task is exact.

## 6. Yes and no mean the same thing everywhere Minga asks

`y` yes (approve once, keep a change), `n` no (deny, reject), `a` always for this session, `t` for this turn. The same keys work in the tasks drawer, the review buffer, the terminal's approval prompt and the TUI. They match today's approval keys.

## 7. Interrupt by need, never by focus

Only "needs you" escalates: first the modeline, then a desktop notification and a Dock badge if Minga is in the background. Nothing steals focus. An approval answered in one place says "Already answered" everywhere else.

## 8. The text keeps its width

Panels yield before code does. The editor keeps at least 100 columns; drawers and splits shrink first, then modeline segments drop in a fixed order.

## 9. Voice at the edges

Minga is Bavarian for Munich, and the voice shows up only at the edges: three lines and no more: "Servus." on welcome, "Passt." once when a task finishes (the notification and the moment it completes), and "Ciao." on quit. "Ciao" is everyday Munich speech. Everywhere else the words are plain: "Done", "Stopped", "Waiting". The agent is called Minga; conversations are named by their goal.

## 10. The keyboard is how you discover

Press `SPC` (or any prefix) and pause: which-key shows what comes next, with live counts. `:` runs commands. Hold ⌘ on macOS to reveal shortcuts on visible controls. Resting surfaces carry no hint lines or key legends. Transient surfaces, the ones that exist only to be acted on, show every action with its key, in the form "`y` Approve once". Not mysterious, just quiet: Neovim and Doom Emacs, with Mac polish.

## The test that keeps both frontends honest

If a macOS screen cannot be drawn in the terminal with the same layout, it is probably wrong. Rendering may be platform-native; the interaction model may not be.
