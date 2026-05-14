# File Tree Visual Spec

The file tree should read like a project cockpit: clear project context first, readable hierarchy second, and status signals third. This spec is the review target for the file-tree visual polish epic, especially [#1638](https://github.com/jsmestad/minga/issues/1638) and the concrete artifact slice [#1648](https://github.com/jsmestad/minga/issues/1648).

Minga should feel familiar to users coming from AstroNvim Neo-tree, Doom Emacs, or Treemacs, but it should not copy terminal branch art or GUI-only decoration when those make the tree harder to scan. The shared rule is: every frontend renders the same semantic state with equivalent priority, even when the visual treatment differs by platform.

## Review target

A file-tree PR moves Minga toward the target when a reviewer can answer yes to these questions:

1. Can I tell which project/root this tree belongs to without reading a path dump?
2. Can I tell the selected tree row apart from the active editor file?
3. Can I tell whether the tree itself has focus?
4. Can I see dirty buffer, git, and diagnostic state without those badges competing with the filename?
5. Can a deeply nested file keep its basename and status indicators visible in a narrow tree?
6. Can a macOS user and a TUI user understand the same states, even if one sees rounded backgrounds and the other sees cells?
7. Can VoiceOver, future screen-reader paths, and color-limited themes expose the same essential meaning without relying only on color?

## Row anatomy

Each visible row is a semantic row, not a string assembled by one renderer. The BEAM owns the meaning, and each frontend decides how to draw it.

| Slot | Purpose | TUI target | macOS target |
|------|---------|------------|--------------|
| Disclosure | Directory expansion affordance | One compact glyph such as `▾`, `▸`, or a blank spacer | Native chevron or equivalent hit target |
| Indent | Parent/child structure | Quiet guides or spacing, no heavy `├─` / `└─` branch art by default | Consistent leading inset and optional subtle guide |
| Icon | File or directory type | Optional devicon or fallback glyph, fixed column | Devicon or system/fallback icon, fixed column |
| Name | Primary row content | Filename remains the strongest text signal | Filename remains the strongest text signal |
| Inline edit | Temporary input state | Replaces name with edit text and cursor treatment | Text field or editable row state owned by BEAM intent |
| Status | Dirty, git, diagnostics | Right-aligned compact badges where width allows | Trailing badges with stable layout |
| Active accent | Open file marker | Slim marker or text accent independent from selection | Slim accent or secondary highlight independent from selection |
| Selection | Tree cursor | Background when selected, subdued when unfocused | Background when selected, subdued when unfocused |
| Hover/drop | Pointer target | Hover only where TUI supports it; drop target gets explicit marker | Hover and drop target layers, never inferred from filesystem in Swift |

## Row-state matrix

This matrix defines the minimum visible distinction for each state. A renderer may add platform-specific polish, but it must preserve the semantic meaning and priority.

| State | Meaning | TUI treatment | macOS treatment | Accessibility text |
|-------|---------|---------------|-----------------|--------------------|
| Normal file | File exists and has no special state | Default filename color, normal icon | Default text, default icon | `filename, file` |
| Normal directory | Directory exists and may expand | Directory icon or text emphasis, disclosure column if expandable | Folder icon, chevron if expandable | `dirname, folder, expanded/collapsed` |
| Hover | Pointer is over the row | Optional subtle reverse or underline when supported | Subtle hover background, stable action layout | Do not announce unless platform normally does |
| Selected | Tree cursor is on this row | Selection background; name still readable | Selection background; row actions may become visible without layout shift | `selected` |
| Active file | This file is open in the active editor window | Active accent or brighter name, no selection background unless also selected | Active accent or secondary highlight, no selection background unless also selected | `current file` |
| Selected active file | Tree cursor and active editor file are the same row | Selection background plus active accent; do not rely on one color | Selection background plus active accent; active marker remains visible | `selected, current file` |
| Unfocused selection | Tree cursor exists but focus is elsewhere | Dimmer selection background or outline | Lower-emphasis selection background | `selected, tree not focused` where exposed |
| Dirty buffer | Open buffer has unsaved changes | Dirty dot or `●` badge near status slot | Dirty dot badge near trailing status | `modified buffer` |
| Git modified | Worktree file is modified | `M` or themed modified badge in status slot | Modified badge or color token in trailing status | `git modified` |
| Git staged | File has staged changes | `S` badge distinct from modified | Staged badge distinct from modified | `git staged` |
| Git untracked | File is untracked | `?` or `U` badge | Untracked badge | `git untracked` |
| Git conflict | File has unresolved conflict | High-priority conflict badge, visible on selection | Conflict badge with warning/error color | `git conflict` |
| Diagnostics error | Highest diagnostic severity is error | Error badge before lower-priority badges | Error badge with count when available | `diagnostics error` or `N errors` |
| Diagnostics warning | Highest diagnostic severity is warning | Warning badge if no error | Warning badge with count when available | `diagnostics warning` or `N warnings` |
| Diagnostics info | Highest diagnostic severity is info | Low-emphasis info badge if space allows | Low-emphasis info badge | `diagnostics info` |
| Diagnostics hint | Highest diagnostic severity is hint | Lowest-emphasis hint badge if space allows | Lowest-emphasis hint badge | `diagnostics hint` |
| Inline edit | User is creating or renaming a row | Edit text replaces name; status and selection remain stable | Editable row or field, with BEAM-owned commit/cancel intent | `editing name` |
| Drop target | Drag/drop intent targets this row or parent directory | Explicit drop marker or highlighted row | Explicit drop highlight, with file targets resolved by BEAM | `drop target` |
| Hidden | Tree is intentionally hidden | No tree rows; editor layout owns the space | SwiftUI tree view hidden or width collapsed | Not exposed as empty tree |
| Loading | Tree exists but rows are not ready | One loading row with project context | Friendly loading state with stable header | `loading project tree` |
| Empty | Tree is visible and has no rows | One empty row with action hint when space allows | Friendly empty state with refresh/open action where available | `empty project tree` |
| Error | Tree failed to load | Error row with concise reason and refresh hint | Error state with reason and retry action | `project tree error` |

## Visual priority rules

Render states as layers, not as mutually exclusive colors. The same row can be selected, active, dirty, git modified, and diagnostic-error at the same time.

1. Inline edit wins the name slot because the user is editing text, but it must not erase selection, focus, or status slots.
2. Drop target wins the pointer layer because the user is about to perform an action, but it must not hide conflict or error badges.
3. Selected row owns the background layer. Focus decides whether that background is strong or subdued.
4. Active file owns a separate accent layer. It must stay visible when the row is selected and when the tree is unfocused.
5. Diagnostics own the highest-priority status badge because they represent code health and can block work.
6. Dirty buffer state appears before git state because it describes unsaved editor state, not repository state.
7. Git conflict outranks other git badges. Modified, staged, untracked, renamed, and deleted remain visible when width allows.
8. Directory emphasis should help scanning, not overpower file names. Expanded folders can be slightly stronger than collapsed folders, but the tree should not look like a column of bold labels.
9. Ignored or hidden files, when shown, are dimmed after all critical badges are placed.
10. Color is a supplement. Shape, text, badge glyphs, accessibility labels, and position carry the meaning first.

## Header target

The header communicates project context, not decoration. The primary label is the project name or root basename. The secondary label can show a compact root path, branch, or filter state when available.

Common actions should be discoverable without shifting layout. New file, new folder, refresh, and collapse all can be visible, shown on hover, or discoverable through keyboard help, but their reserved space should not cause the title to jump when the pointer moves.

The TUI header should use the same hierarchy in cells: project name first, secondary context dimmer, actions compact. The macOS header can use native buttons, tooltips, and accessibility labels, but Swift should send intents to the BEAM instead of mutating the filesystem locally.

## Deep nesting and truncation

Deep projects should preserve meaning before preserving full paths. When width is tight, keep the basename and status badges before decorative indentation.

TUI truncation must account for display width, including emoji, CJK, combining marks, and devicons. It should reserve columns for disclosure, icon, active accent, and status before shortening names. A deeply nested row can collapse some visual guides, but it should not hide whether the file has diagnostics, dirty state, or a git conflict.

macOS rows should keep chevrons, icons, names, and status badges aligned at common depths. If a sticky parent or equivalent context is introduced, it must not obscure content or duplicate the selected row.

## Competitive parity checklist

Use this as a practical checklist when comparing Minga against polished file-tree experiences.

### AstroNvim Neo-tree basics

- [ ] Selected row is obvious but not visually loud.
- [ ] Active/open file is distinct from selected row.
- [ ] Modified, staged, untracked, and conflict states are visible as compact badges.
- [ ] Dirty buffers are visible independently from git state.
- [ ] Expanded and collapsed folders are scannable without excessive connector noise.
- [ ] Hidden or ignored files are lower emphasis when shown.
- [ ] Root/project context is visible near the top of the tree.
- [ ] Common actions are discoverable through key help or visible affordances.

### Doom Emacs and Treemacs basics

- [ ] Project root is clear.
- [ ] Current file can be followed or recognized in the tree.
- [ ] Git and diagnostics indicators do not compete with filenames.
- [ ] File operations are reachable without leaving the tree mental model.
- [ ] Directory expansion is fast and predictable.
- [ ] Deeply nested files remain readable.
- [ ] Mouse interactions are first-class where the frontend supports a pointer.
- [ ] Accessibility labels and keyboard paths expose the same actions as pointer affordances.

### Minga differences by design

Minga keeps file operations BEAM-owned. Native frontends render rows and report intents; they do not directly copy, move, rename, or delete files.

Minga uses a shared semantic row contract. The TUI and macOS GUI should not independently infer active file, dirty buffer, git status, diagnostics, or editing state.

Minga avoids full-screen snapshots for most tree work. Targeted protocol, row-state, render tuple, and Swift view/state tests are preferred because project files and absolute paths make broad snapshots brittle.

## Theme and accessibility notes

Dark and light themes need separate review because subtle backgrounds can disappear in one mode while looking balanced in the other. Selection, active accent, diagnostics, dirty, and git badges should be checked against both theme families.

Contrast must remain acceptable when a status badge sits on selected, active, hovered, and unfocused rows. If a theme cannot support all status colors clearly, badges should fall back to stable glyphs or labels rather than color alone.

Icon fallback is required. A missing devicon font should not leave blank columns or erase file type meaning. Fallbacks can be simple folder/file glyphs or text markers.

VoiceOver labels should include row name, type, selected state, current-file state, expanded/collapsed state, dirty state, git state, diagnostics summary, and available custom actions where practical. TUI output should preserve readable text and not encode essential meaning only in ANSI color.

Reduced-motion settings should apply to header actions, row hover transitions, expansion animations, and loading states in native GUI frontends.

## Lightweight mock examples

These examples are not a wire format. They are quick review prompts for the visual result.

### Good: selected row and active file are distinct

```text
PROJECT minga                         +  folder  refresh
▾  lib
  ▾ minga_editor
    ● editor.ex                  M  ⚠2  <- active file accent plus dirty/git/diagnostics
  ▸ test
▶   docs/FILE_TREE_VISUAL_SPEC.md  ?    <- selected tree row
```

Review prompt: can I point to the cursor row and the open editor file without reading modeline state?

### Good: deeply nested file keeps basename and status

```text
PROJECT minga
▾  lib
  ▾ .../render_pipeline/chrome
      gui_status_bar.ex          M  E1
```

Review prompt: did truncation keep `gui_status_bar.ex`, `M`, and `E1` before preserving every parent segment?

### Bad: branch art beats content

```text
├── lib
│   ├── minga_editor
│   │   ├── shell
│   │   │   ├── traditional
│   │   │   │   ├── render_pipeline
│   │   │   │   │   └── chrome
```

Review prompt: does this look like a diagram first and a navigator second? If yes, calm the guides.

### Bad: one color tries to mean everything

```text
blue row = selected, active, dirty, git modified, focused
```

Review prompt: which part of the row tells me the buffer is dirty after focus moves away? If the answer is only color, split the layers.

## Regression coverage guidance

Prefer the lightest test layer that proves the state mapping.

- Row contract tests should cover selected, focused, active, dirty, git-marked, diagnostic-marked, inline-edited, nested, hidden, loading, empty, and error rows.
- Protocol tests should cover unicode byte lengths, empty states, hidden states, malformed entries, and combined state payloads.
- TUI render tests should assert tuple or row text structure, reserved status columns, and width-aware truncation.
- Swift tests should assert decoded state and row view/state behavior without making Swift infer filesystem, git, dirty, or diagnostics locally.
- Snapshot tests should be a last resort for states that cannot be asserted through protocol, row, or view models.

When a PR intentionally changes the visual system, include before/after screenshots or text mock output in the PR description. The evidence should show selected versus active, focused versus unfocused, status badges on selected rows, and at least one deeply nested row.

## Follow-up boundaries

Do not fold Dired-level bulk operations into the visual polish workstream. Bulk mark, batch delete, batch rename, permissions editing, and recursive operation previews are separate product work.

Do not replace the file-tree architecture wholesale as part of visual polish. The epic should close the visual contract gap first: shared semantic rows, versioned GUI protocol, equivalent frontend rendering, and targeted regression coverage.

Do not add project indexing beyond what visible file-tree state needs. If a status badge requires broader indexing, capture it as a separate performance or project-system ticket before expanding this epic.
