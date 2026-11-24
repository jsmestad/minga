# Themes and colour roles

Minga is themeable. Users pick a theme (`set :theme, :catppuccin_frappe`), and every colour on screen comes from it. So the design never says "purple" or `#a463e6`; it says **minga**, and each theme decides what minga looks like.

**The default theme is Catppuccin Frappé** (`:catppuccin_frappe`), the theme closest to the design. Astrodark stays as a built-in. Every hex value quoted in these docs is a Frappé example, nothing more. (The code change that makes Frappé the default lands in its own PR.)

This page lists the roles the design uses, where each one lives in `MingaEditor.UI.Theme`, and how the reference themes fill them. The roles themselves are defined once, in [`docs/design_tokens.toml`](../design_tokens.toml), together with the six state words and shapes, the twist variants and the voice lines. `mix codegen` turns that file into `Minga.Design.Tokens` (Elixir), `DesignTokens.generated.swift` (macOS) and `design_tokens.go` (TUI), so both frontends draw the same word, shape and role for every state.

## The rules

- **Frontends never use hex.** Swift and Go draw a role the BEAM sends (theme slots in `MingaEditor.UI.Theme.Slots`), never a literal colour. A colour literal in a view is a bug. Each role has its own slot (0x70 to 0x8F); Swift reads it with `ThemeColors.roleColor(_:)` and Go with `palette.Role`. `test/minga/render_model/frontend_token_guardrails_test.exs` fails on a new colour literal in Swift or Go view code; the literals that predate it are listed in a baseline that only shrinks.
- **One role, one meaning.** You is you, minga is Minga, needs-you is only "Minga needs you", failure is only failure, done is only done. A theme may make needs-you pink if it likes, but it may not reuse that value for something else on the same screen.
- **Shapes carry meaning without colour.** Every state is a shape plus a word (see [marks](marks.md#the-orbit)), so a theme with weak hues, a colour-blind user, or a 16-colour terminal still reads every state.
- **Contrast targets.** Against the surface they sit on: at least **3:1** for glyphs, strands, the focused border and the needs-you chip (WCAG non-text contrast), and at least **4.5:1** for text. Light themes are where this fails first. The token file records each role's target class and the surface it is measured on, and `test/minga_editor/ui/theme/role_contrast_test.exs` checks every built-in theme. Quiet pane borders and secondary text (line numbers) carry no target: they are meant to recede, and the focused border is the one that must be seen.
- **Derived colours are computed, not configured.** The twist's shade strand and the diff tints are mixes of a role over the background, so a new theme gets them for free.
- **The TUI degrades through the colour profile.** Truecolor roles map down to 256 and 16 colours (see [tui.md](tui.md#colour-profiles)); the 16-colour mapping of each role is part of the theme, not guessed per screen.
- **Every scenario renders in more than one theme.** The storyboard factory renders each scenario in catppuccin_frappe (the default), astrodark, and one light theme (catppuccin_latte or one_light). See [storyboard.md](storyboard.md).

## Roles

Every role below is a token in `docs/design_tokens.toml`. "Theme field" is the `MingaEditor.UI.Theme` field that supplies the value; `MingaEditor.UI.Theme.role_color/2` resolves a role for any theme.

| Role | Means | Theme field | Target |
|---|---|---|---|
| you | Your edits, cursor, messages, your strand in the gutter | `agent.user_label` | 3:1 |
| minga | Minga, its cursor tag, its changes, the light twist strand, the working orbit | `agent.minga_fg` | 3:1 |
| minga_shade | The twist's shade strand, Minga's tinted lines | derived: minga mixed over surface at 45% | none |
| needs_you | Only "Minga needs you": the modeline chip, the needs-you state | `agent.attention_fg` | 3:1 |
| failure | Errors, failed states, red diagnostics | `gutter.error_fg` | 3:1 |
| done | Completed states | `agent.status_done` | 3:1 |
| warning | Diagnostic warnings only | `gutter.warning_fg` | 3:1 |
| waiting | The hollow dot of Waiting and Stopped, and its words | `agent.status_idle` | 3:1 |
| info | Diagnostic info and hints | `gutter.info_fg` | 3:1 |
| group | Which-key and menu group labels, with their chevron | `popup.group_fg` | 4.5:1 on surface_raised |
| text | Primary text | `editor.fg` | 4.5:1 |
| text_muted | Secondary text, line numbers, hints | `gutter.fg` | none |
| surface | Editor background | `editor.bg` | |
| surface_raised | Drawers, which-key, menus, popups | `popup.bg` | |
| surface_bar | The modeline | `modeline.bar_bg` | |
| border | Quiet pane borders | `popup.border_fg` | none |
| focus | The focused pane's border and the global accent | `popup.title_fg` | 3:1 |
| selection | The selected row in a focused list | macOS: system accent. TUI: `editor.selection_bg` | not a token: it is platform-specific |
| diff_added_tint, diff_removed_tint | Review and diff line backgrounds | derived: `git.added_fg` and `git.deleted_fg` mixed over `editor.bg` | not a token yet |
| mode pills | NORMAL, INSERT, and so on | `modeline.mode_colors` | not a token |

Theme authors set the new roles through the palette keys `minga`, `needs_you`, `done`, `waiting` and `group` (see `MingaEditor.UI.Theme.Palette.Semantic`). A theme that leaves them out gets defaults: done follows success, waiting follows muted, and group follows the highlight colour.

### States

Each state is a token too: a word, a shape, a colour role, a TUI glyph and a VoiceOver label (see [marks](marks.md#the-orbit)). The agent status slots in `gui_theme` carry the colour of the state each status shows, resolved through the state's role.

| State | Word | Shape | Role | TUI |
|---|---|---|---|---|
| working | Working | orbit | minga | `◐`, cycling `◐ ◓ ◑ ◒` |
| needs_you | Needs you | halo dot | needs_you | `◉` |
| waiting | Waiting | hollow dot | waiting | `○` |
| stopped | Stopped | hollow dot | waiting | `○` |
| failed | Failed | diamond | failure | `◆` |
| done | Done | solid dot | done | `●` |

### Conflicts fixed

Two agent fields broke "one role, one meaning". Both now follow the minga role in every built-in theme:

- `agent.assistant_label` was green in astrodark, catppuccin_frappe and catppuccin_latte, and green means done. Minga's label now uses **minga**.
- `agent.status_thinking` was yellow, too close to needs-you. Working is drawn in **minga** with the moving orbit, so thinking uses minga as well.

## The reference themes

Values are read from the built structs (`MingaEditor.UI.Theme.CatppuccinFrappe.theme/0`, `AstroDark.theme/0`, `CatppuccinLatte.theme/0`) through `role_color/2`.

| Role | catppuccin_frappe (default) | astrodark | catppuccin_latte |
|---|---|---|---|
| surface | `#303446` | `#1A1D23` | `#EFF1F5` |
| surface_raised | `#414559` | `#14161B` | `#CCD0DA` |
| surface_bar | `#292C3C` | `#111317` | `#E6E9EF` |
| text | `#C6D0F5` | `#ADB0BB` | `#4C4F69` |
| text_muted | `#838BA7` | `#595C66` | `#8C8FA1` |
| you | `#8CAAEE` | `#50A4E9` | `#1E66F5` |
| minga | `#CA9EE6` (mauve) | `#DD97F1` | `#8839EF` (mauve) |
| minga_shade | `#75648E` | `#725480` | `#C19EF2` |
| needs_you | `#EF9F76` (peach) | `#F5983A` | `#D35400` (darkened peach) |
| failure | `#E78284` | `#F8747E` | `#D20F39` |
| done | `#A6D189` | `#75AD47` | `#388E25` (darkened green) |
| warning | `#E5C890` | `#D09214` | `#A86D10` (darkened yellow) |
| waiting | `#838BA7` | `#696C76` | `#7C7F93` (overlay2) |
| group | `#BABBF1` (lavender) | `#50A4E9` | `#1650C0` (darkened blue) |

### Contrast

Ratios against the surface each role sits on (the editor background, or surface_raised for group).

| Role | catppuccin_frappe (default) | astrodark | catppuccin_latte |
|---|---|---|---|
| you | 5.3 | 6.3 | 4.3 |
| minga | 5.6 | 7.9 | 4.8 |
| needs_you | 5.8 | 7.6 | 3.7 |
| failure | 4.6 | 6.3 | 4.8 |
| done | 7.1 | 6.3 | 3.7 |
| waiting | 3.6 | 3.2 | 3.5 |
| warning | 7.6 | 6.3 | 3.8 |
| group (text) | 5.2 | 6.7 | 4.6 |
| text (text) | 8.1 | 7.8 | 7.1 |

Every built-in theme now meets its targets. The fixes that got there:

- **Latte** darkens needs-you (`#D35400`), warning (`#A86D10`), done (`#388E25`) and group (`#1650C0`), and moves waiting up one step on the neutral ramp to overlay2. Each keeps its Catppuccin hue.
- **astrodark** moves waiting up one step on its neutral ramp, to the comment grey `#696C76`.
- **Catppuccin Frappé, Macchiato and Mocha** draw group labels in lavender, which reads at 4.5:1 on the popup surface.
- **doom_one, one_dark and one_light** move waiting off the line-number grey to a value that reaches 3:1, and one_dark and one_light lift group labels to 4.5:1.

These are theme fixes, not design changes, and the storyboard factory's light-theme renders are how they stay fixed.

## On the design canvas

Most canvas boards were drawn in an astrodark-like palette before Frappé became the default. The Catppuccin Frappé and Latte boards on the canvas are automatic remaps of the same boards, made to show the default and a light theme; they are not hand-tuned, and a few of their colours (inset strips, tints) are only approximate. New boards should be drawn in Frappé.
