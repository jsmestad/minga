# Built-in theme upstream audit (#1727)

This audit compares Minga's non-Doom-One built-in themes against their canonical upstream sources after the semantic theme layer landed. Doom One is excluded here because #1725 is being fixed in a separate worktree.

## Summary

| Theme | Palette status | Semantic status | Fix ticket |
|-------|----------------|-----------------|------------|
| One Dark | Mostly matches Atom, with a low-priority `mono-2` exactness check | Drift in operators, variables, regex, selection, and git modified | #1738 |
| One Light | Matches Atom HSL declarations | Same drift pattern as One Dark | #1739 |
| Catppuccin Latte, Frappé, Macchiato, Mocha | Exact match against official palette JSON | Drift in links, builtins, comments, info, search, line numbers, regex, symbols, properties, and attributes | #1737 |

## Sources checked

- One Dark: `atom/one-dark-syntax` `styles/colors.less`, `styles/syntax-variables.less`, and `styles/syntax/_base.less`
- One Light: `atom/one-light-syntax` `styles/colors.less`, `styles/syntax-variables.less`, and `styles/syntax/_base.less`
- Catppuccin: `catppuccin/palette` `palette.json` and `catppuccin/catppuccin` style guide

## One Dark discrepancy list

### Palette

- Most palette values match the upstream Atom HSL declarations.
- `mono-2` should be checked against the resolved CSS value for `hsl(220, 9%, 55%)`. Minga has `#818896`; common resolved values are closer to `#828997`. This is an exactness check, not the main visual bug.

### Semantic and syntax assignments

- `keyword.operator` maps to purple, but upstream `.syntax--keyword.syntax--operator` maps to `@mono-1`.
- `variable` maps to default foreground, but upstream `.syntax--variable` maps to `@hue-5` red.
- `variable.parameter` maps to red, but upstream `.syntax--variable.syntax--parameter` maps to `@mono-1`.
- `property` and `field` map to cyan, while upstream `@syntax-color-property` is `@syntax-fg`. XML and HTML attribute-name captures should remain separate and orange.
- `operator` maps to cyan. Atom only calls out keyword operators as foreground, so generic tree-sitter operators should probably derive from the same semantic operator slot.
- `string.regex` and `string.special.regex` map to orange, but upstream `.syntax--string.syntax--regexp` maps to `@hue-1` cyan.

### UI-level mappings

- `editor.selection_bg` is `#264F78`, but upstream `@syntax-selection-color` is `lighten(@syntax-background-color, 10%)`, approximately `#3E4451`.
- `git.modified_fg` is blue, but upstream `@syntax-color-modified` is `hsl(40, 60%, 70%)`, approximately `#E0C285`.
- If represented directly, selected gutter/current line background should derive from `lighten(@syntax-bg, 8%)`, approximately `#3A404B`.

### Intentional Minga-specific deviations to decide

- Atom `one-dark-syntax` does not define Minga chrome like agent panel, dashboard, tree sidebar, tab bar, or picker. Those should derive from the semantic layer rather than copying explicit legacy values.

## One Light discrepancy list

### Palette

- Palette values match the upstream Atom HSL declarations.

### Semantic and syntax assignments

- `keyword.operator` maps to purple, but upstream `.syntax--keyword.syntax--operator` maps to `@mono-1`.
- `variable` maps to default foreground, but upstream `.syntax--variable` maps to `@hue-5` red.
- `variable.parameter` maps to red, but upstream `.syntax--variable.syntax--parameter` maps to `@mono-1`.
- `property` and `field` map to cyan, while upstream `@syntax-color-property` is `@syntax-fg`. XML and HTML attribute-name captures should remain separate and orange.
- `operator` maps to cyan. Atom only calls out keyword operators as foreground, so generic tree-sitter operators should probably derive from the same semantic operator slot.
- `string.regex` and `string.special.regex` map to orange, but upstream `.syntax--string.syntax--regexp` maps to `@hue-1` cyan.

### UI-level mappings

- `editor.selection_bg` is `#BDD5FC`, but upstream `@syntax-selection-color` is `darken(@syntax-bg, 8%)`, approximately `#E6E6E6`.
- `git.modified_fg` is blue, but upstream `@syntax-color-modified` is `hsl(40, 90%, 50%)`, approximately `#F2A60D`.
- If represented directly, selected gutter/current line background should derive from `darken(@syntax-bg, 8%)`, approximately `#E6E6E6`.

### Intentional Minga-specific deviations to decide

- Atom `one-light-syntax` does not define Minga chrome like agent panel, dashboard, tree sidebar, tab bar, or picker. Those should derive from the semantic layer rather than copying explicit legacy values.

## Catppuccin discrepancy list

### Palette

- Latte, Frappé, Macchiato, and Mocha exactly match the official `catppuccin/palette` JSON values.
- No palette value changes are needed in the flavor modules.

### Semantic and syntax assignments

- `link` maps to `rosewater`, but the style guide says links and URLs should use `blue`.
- `builtin` maps to `teal`, but the style guide says builtins should use `red`.
- `comments` maps to `overlay0`, and syntax comments use `overlay0` or `overlay1`; the style guide says comments should use `overlay2`.
- `info` maps to `blue`, but the style guide says information should use `teal`.
- `search.highlight_bg` uses `yellow`, but the style guide says search background should use `teal`; current search background as `red` is correct.
- `gutter.fg` uses `overlay0`, but the style guide says line numbers should use `overlay1`.
- `gutter.current_fg` uses `text`, but the style guide says active line numbers should use `lavender`.
- `string.special.regex` and `string.regex` use `peach`, but the style guide says escape sequences and regex should use `pink`.
- `string.special.symbol` uses `flamingo` and `character` uses `teal`; the style guide says symbols and atoms should use `red`.
- `variable.member`, `field`, and `property` use `teal`; the style guide says properties, such as JSON keys, should use `blue`.
- `attribute` uses `teal`; the style guide says XML-style attributes should use `yellow`. `tag.attribute` already uses yellow.

### UI-level mappings

- `popup.sel_bg` uses full blue. The general style guide says selection backgrounds should use overlay2 at 20% to 30% opacity. Because Minga cannot express alpha in every surface, the fix ticket should decide whether `surface2` or `overlay2` is a better opaque approximation, or document full blue as an intentional accent-selection deviation.

### Intentional Minga-specific deviations to decide

- Catppuccin explicitly leaves some editor-port choices to judgment. Minga-specific chrome can keep opinionated mappings, but they should be derived from semantic palette slots so all four flavors remain consistent.

## Fix tickets created

- #1738: One Dark theme matches upstream `atom/one-dark-syntax`
- #1739: One Light theme matches upstream `atom/one-light-syntax`
- #1737: Catppuccin themes match official palette and style guide semantics
