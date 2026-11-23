# Themes and colour roles

Minga is themeable. Users pick a theme (`set :theme, :catppuccin_frappe`), and every colour on screen comes from it. So the design never says "purple" or `#a463e6`; it says **minga**, and each theme decides what minga looks like. The hex values on the design canvas are astrodark defaults, nothing more.

This page lists the roles the design uses, where each one lives in `MingaEditor.UI.Theme` today, and which ones do not exist yet. It also records how the three reference themes fill them and where a theme misses the contrast targets.

## The rules

- **Frontends never use hex.** Swift and Go draw a role the BEAM sends (theme slots in `MingaEditor.UI.Theme.Slots`), never a literal colour. A colour literal in a view is a bug.
- **One role, one meaning.** You is you, minga is Minga, needs-you is only "Minga needs you", failure is only failure, done is only done. A theme may make needs-you pink if it likes, but it may not reuse that value for something else on the same screen.
- **Shapes carry meaning without colour.** Every state is a shape plus a word (see [marks](marks.md#the-orbit)), so a theme with weak hues, a colour-blind user, or a 16-colour terminal still reads every state.
- **Contrast targets.** Against the surface they sit on: at least **3:1** for glyphs, strands, borders and the needs-you chip (WCAG non-text contrast), and at least **4.5:1** for text. Light themes are where this fails first.
- **Derived colours are computed, not configured.** The twist's shade strand and the diff tints are mixes of a role over the background, so a new theme gets them for free.
- **The TUI degrades through the colour profile.** Truecolor roles map down to 256 and 16 colours (see [tui.md](tui.md#colour-profiles)); the 16-colour mapping of each role is part of the theme, not guessed per screen.
- **Every scenario renders in more than one theme.** The storyboard factory renders each scenario in at least astrodark, catppuccin_frappe and one light theme (catppuccin_latte or one_light). See [storyboard.md](storyboard.md).

## Roles

"New role" means the Theme struct has no field for it yet; the section named is where it belongs.

| Role | Means | Theme field today | Status |
|---|---|---|---|
| you | Your edits, cursor, messages, your strand in the gutter | `agent.user_label` | exists |
| minga | Minga, its cursor tag, its changes, the light twist strand, the working orbit | none | **new role** in `agent` (`minga_fg`) |
| minga_shade | The twist's shade strand, Minga's tinted lines | none | derived: minga mixed over `editor.bg` (about 45%) |
| needs_you | Only "Minga needs you": the modeline chip, the needs-you state | none (`tab_bar.attention_fg` exists but is red, the failure colour, in every built-in theme) | **new role** in `agent` (`attention_fg`) |
| failure | Errors, failed states, red diagnostics | `gutter.error_fg`, `agent.status_error` | exists |
| done | Completed states | none for state (`git.added_fg` is the same hue in built-in themes) | **new role** in `agent` (`status_done`) |
| waiting | The hollow waiting dot and its words | `agent.status_idle` | exists |
| warning | Diagnostic warnings only | `gutter.warning_fg` | exists |
| info | Diagnostic info and hints | `gutter.info_fg` | exists |
| text | Primary text | `editor.fg` | exists |
| text_muted | Secondary text, line numbers, hints | `gutter.fg` | exists |
| surface | Editor background | `editor.bg` | exists |
| surface_raised | Drawers, which-key, menus, popups | `popup.bg` | exists |
| surface_bar | The modeline | `modeline.bar_bg` | exists |
| border | Quiet pane borders | `popup.border_fg`, `editor.split_border_fg` | exists |
| border_focus | The focused pane's border | the GUI accent slot (`0x40`) | exists |
| selection | The selected row in a focused list | macOS: system accent. TUI: `editor.selection_bg` | exists |
| diff_added_tint, diff_removed_tint | Review and diff line backgrounds | none | derived: `git.added_fg` and `git.deleted_fg` mixed over `editor.bg` |
| mode pills | NORMAL, INSERT, and so on | `modeline.mode_colors` | exists |

### Conflicts in today's themes

Two existing agent fields break "one role, one meaning" and need reassigning when the Spine lands:

- `agent.assistant_label` is green in astrodark, catppuccin_frappe and catppuccin_latte. Green means done, so Minga's label moves to the new **minga** role.
- `agent.status_thinking` is yellow in the same themes, too close to needs-you. Working is drawn in **minga** with the moving orbit, so thinking moves to minga as well.

## The reference themes

Values are read from the built structs (`MingaEditor.UI.Theme.AstroDark.theme/0`, `CatppuccinFrappe.theme/0`, `CatppuccinLatte.theme/0`). For the new roles, the value shown is the palette colour the theme would assign: astrodark's syntax purple and orange, and Catppuccin's mauve and peach.

| Role | astrodark (default) | catppuccin_frappe | catppuccin_latte |
|---|---|---|---|
| surface (`editor.bg`) | `#1A1D23` | `#303446` | `#EFF1F5` |
| text (`editor.fg`) | `#ADB0BB` | `#C6D0F5` | `#4C4F69` |
| text_muted (`gutter.fg`) | `#595C66` | `#838BA7` | `#8C8FA1` |
| surface_raised (`popup.bg`) | `#14161B` | `#414559` | `#CCD0DA` |
| surface_bar (`modeline.bar_bg`) | `#111317` | `#292C3C` | `#E6E9EF` |
| you (`agent.user_label`) | `#50A4E9` | `#8CAAEE` | `#1E66F5` |
| minga (new) | `#DD97F1` | `#CA9EE6` (mauve) | `#8839EF` (mauve) |
| needs_you (new) | `#F5983A` | `#EF9F76` (peach) | `#FE640B` (peach) |
| failure (`gutter.error_fg`) | `#F8747E` | `#E78284` | `#D20F39` |
| done (new) | `#75AD47` | `#A6D189` | `#40A02B` |
| waiting (`agent.status_idle`) | `#595C66` | `#838BA7` | `#8C8FA1` |
| warning (`gutter.warning_fg`) | `#D09214` | `#E5C890` | `#DF8E1D` |

### Contrast against the editor background

| Role | astrodark | catppuccin_frappe | catppuccin_latte |
|---|---|---|---|
| you | 6.3 | 5.3 | 4.3 |
| minga | 7.9 | 5.6 | 4.8 |
| needs_you | 7.6 | 5.8 | **2.6** |
| failure | 6.3 | 4.6 | 4.8 |
| done | 6.3 | 7.1 | 3.0 |
| waiting | **2.5** | 3.6 | **2.8** |
| warning | 6.3 | 7.6 | **2.3** |

Bold values miss the 3:1 target for glyphs and strands. What that means for the light theme and for astrodark:

- **Needs-you in Latte** cannot be a bare peach glyph. Either the theme supplies a darker value for the role, or the needs-you chip is drawn as filled peach with dark text, which passes because the text is measured against the chip.
- **Warning in Latte** fails as an underline colour. The theme needs a darker warning value; the dotted shape still separates it from errors meanwhile.
- **Waiting** fails in astrodark and Latte because it reuses the muted text colour. The waiting glyph needs its own value at 3:1, or `agent.status_idle` moves up one step on each theme's neutral ramp.

These are theme fixes, not design changes, and the storyboard factory's light-theme renders are how they stay fixed.

## On the design canvas

The canvas boards use astrodark-like defaults. The Catppuccin Frappé and Latte boards on the canvas are automatic remaps of the same boards, made to show that the design survives a theme change; they are not hand-tuned, and a few of their colours (inset strips, tints) are only approximate.
