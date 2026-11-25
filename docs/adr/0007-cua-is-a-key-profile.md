# ADR-0007: CUA is a key profile with its own platform conventions

**Status:** Accepted (2026-11-23). Builds on [ADR-0006](0006-the-spine.md) and [principle 11](../design/principles.md#11-keys-are-chords-and-mnemonics). Follow-up: teach the key-grammar guard the profile and delete its baseline rows.

## Decision

CUA is a named key profile. A user who sets `:editing_model` to `:cua` gets the desktop conventions they chose, and the key grammar treats those conventions as correct rather than as violations.

Within the CUA profile, an explicit allow-list of platform conventions is exempt from grammar rules 4 and 5:

- **Clipboard and history:** ⌘C, ⌘V, ⌘X, ⌘Z, ⇧⌘Z, ⌘A on macOS, and ⌃C, ⌃V, ⌃X, ⌃Z, ⌃Y, ⌃A on Linux and in the terminal. These may be the only binding for their action, not just aliases.
- **Command palette:** ⌃P and ⌃⇧P.
- **New line without sending in the composer:** ⌃J and ⌥↩.

Everything else in the grammar still applies inside the profile:

- **One key, one meaning per context.** A CUA key may not mean copy in one surface and "open commit" in another.
- **No editing-key collisions in prompts.** Pickers, the minibuffer and other live prompts keep the prompt rules: you move into the list with ⌃J / ⌃K or the arrows, and typing edits the query.
- **Rule 6 is not relaxed.** No three-modifier chords, no ⌃⌘ or ⌥⌘ combinations, no function keys.
- **Leader sequences stay available.** The profile adds desktop conventions; it does not remove the mnemonic leader layer.

The allow-list lives next to the guard's other allow-lists, in `test/support/key_grammar.ex`, so adding a convention is a reviewed change, not a baseline row.

## Amendment: Diff Review chords (2026-11-24)

A focused staged Diff Review is its own grammar context, not a second meaning in the Agent scope underneath it (#4185). Inside the CUA review only, these chords are exempt from rules 4 and 5, each for the command it names:

- ⌘↩ and ⌃↩: keep the hunk (`agent_accept_hunk`).
- ⌘⌫ and ⌃⌫: reject the hunk (`agent_reject_hunk`).
- ⇧⌘↩ and ⌃⇧↩: keep every hunk (`agent_accept_all_hunks`).
- ⇧⌘⌫ and ⌃⇧⌫: reject every hunk (`agent_reject_all_hunks`).
- ⌥↓ and ⌥↑: next and previous hunk (`agent_next_code_block`, `agent_prev_code_block`).

⌘↩ and ⌘⌫ are the keep and undo pair Cursor and VS Code use for agent edits. The ⌃ forms exist because a terminal cannot send ⌘. These chords are not CUA conventions outside the review, and rule 6 still applies inside it. The full key table is in [keys.md](../design/keys.md#diff-review).

## Context

Minga is Vim-first, and the key grammar in principle 11 is written for Vim users: leader sequences first, modifiers only where letters must type text, macOS platform keys only as aliases. That grammar is right for the default profile.

Some users choose `:editing_model :cua` because they want the shortcuts every desktop app uses. For them, ⌘C copies, ⌃Z undoes, and ⌘A selects all. Those keys are not "unconventional modifiers"; they are the convention.

When the key-grammar guard landed, it classified every CUA binding with the Vim rules. The baseline recorded 36 CUA rows:

| Rule | Rows |
|---|---|
| `platform_key` | 12 |
| `unconventional_modifier` | 10 |
| `duplicate_key` | 7 |
| `normal_mode_modifier` | 5 |
| `editing_collision` | 2 |

Most of them are the profile working as intended. Treating them as debt would push the migration to remove desktop shortcuts from the users who asked for them.

## Consequences

- **The guard learns the profile in a follow-up.** `key_grammar.ex` gains a CUA allow-list, and the grammar test classifies CUA bindings against it. The `platform_key`, `unconventional_modifier`, `normal_mode_modifier` and `editing_collision` rows for listed conventions then leave the baseline.
- **Real conflicts stay real.** The seven `duplicate_key` rows are genuine double meanings (for example ⌃C and ⌘C opening a commit in git status while copying elsewhere). They stay in the baseline until the bindings are fixed.
- **New CUA keys need a reason.** A desktop shortcut that is not on the allow-list is still a violation; adding it means extending the list with the convention it follows.

## Alternatives rejected

- **Hold CUA to the Vim grammar.** It would remove the shortcuts CUA users chose the profile for.
- **Exempt CUA from the grammar entirely.** One meaning per key and the prompt rules protect CUA users as much as Vim users; dropping them would bring back the collisions the grammar exists to stop.
- **Keep the rows in the baseline indefinitely.** A baseline is for debt that shrinks. Permanent rows would hide which CUA bindings are correct and which are real conflicts.
