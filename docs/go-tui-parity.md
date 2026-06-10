# Go TUI parity audit

This document is the parity gate for making the Go/Bubble Tea frontend the default terminal frontend (epic #2216, flip ticket #2222). It audits every semantic UI surface and input behavior the protocol defines, and records Go's status on each with file:line evidence.

The parity reference is the semantic protocol, not the Zig renderer. The two authorities are `docs/protocol_schema.toml` (opcode registry, wire structures, sections) and `docs/GUI_PROTOCOL.md` (semantic chrome and the `gui_action` input contract). Zig is consulted only where the spec is ambiguous. This supersedes the Go/Charm coverage row in the #2113 inventory, which reported 9/28 components before this work landed.

## Method

The audit drives outward from the schema so a missing surface cannot hide. For every semantic opcode in `protocol_schema.toml` I verified four facts about Go:

- a. BEAM emits it and Go decodes it. BEAM emitters live in `lib/minga/frontend/adapter/gui/` (31 encoders) and `lib/minga_editor/frontend/protocol/gui.ex`. Go decode is dispatched in `go/tui/internal/protocol/commands.go:152` (`DecodeCommand`) and `go/tui/internal/protocol/chrome_decode.go:9` (`decodeChrome`).
- b. Go renders it. Header and footer chrome in `render_chrome.go`, editor body and content sidebars in `render_content.go`, transient overlays in `render_surfaces.go`, floating picker in `picker_overlay.go`, which-key in `which_key_overlay.go`, agent chat in `agent_chat_panel.go`, frame composition in `frame.go`, state wiring in `model.go:179` (`applyCommands`).
- c. Input/mouse routes it. Keyboard, paste, resize, and raw mouse in `input.go`; semantic zone routing in `semantic_mouse.go`; encoders in `protocol/events.go`.
- d. Test or snapshot coverage exists. `internal/protocol/commands_test.go`, `generated_decode_test.go`, `semantic_guardrail_test.go`, `extension_runtime_test.go`, `events_test.go`, and `internal/ui/model_test.go` / `input_test.go`.

A standing guardrail test, `internal/protocol/semantic_guardrail_test.go:9`, enumerates all 41 semantic frontend opcodes and fails the build if any one lacks both a decode path and a parity classification. That test is the machine-checked backstop behind the "decode" column below.

### Validation run

`go test ./...` from `go/tui/` on this branch: 189 passed in 6 packages, suite green. The guardrail and decode tests above are part of that run.

## Status legend

- PASS: decode, render, and (where applicable) input all verified with evidence.
- GAP: missing or broken; the cell says what is missing.
- DIVERGENCE: Go behaves differently on purpose, with a one-line rationale. Non-blocking.
- N/A: surface is not meaningful in a terminal, with rationale.

## Chrome and semantic surfaces

| Surface | Opcode | Decode (a) | Render (b) | Input (c) | Tests (d) | Status |
|---|---|---|---|---|---|---|
| Theme | gui_theme 0x74 | `chrome_editor.go:394` `decodeTheme` | palette swap `model.go:212`, applied everywhere via `m.palette()` | n/a | `model_test.go` TestThemeCommandUpdatesModelPalette | PASS |
| Tab bar | gui_tab_bar 0x71 | `chrome_editor.go:8` `decodeTabBar` | `render_chrome.go:90` `renderTabs` | click → select_tab `semantic_mouse.go:107`, `events.go:75` | commands_test TestDecodeTabBarChromeSummary; model_test TestHeaderTruncatesLongTabLabels, TestSemanticMouseRoutesModelineAndFileTreeZones | PASS |
| Workspaces | gui_workspaces 0x98 | `chrome_editor.go:60` `decodeWorkspaces` | `render_chrome.go:35` `renderWorkspaces` | n/a (keyboard via key_press) | commands_test TestDecodeWorkspaces...; model_test TestWorkspaceRowRendersAsQuietNavigation | PASS |
| Breadcrumb | gui_breadcrumb 0x75 | `chrome_editor.go:408` `decodeBreadcrumb` | `render_chrome.go:129` `renderBreadcrumb` (width >= 100) | breadcrumb_click not routed; keyboard nav works | model_test TestHeaderRendersBreadcrumbWithTabs, TestHeaderHidesBreadcrumbsAtNarrowWidth | PASS (see gap G6 for click) |
| Status bar / modeline | gui_status_bar 0x76 | `chrome_editor.go:284` `decodeStatus` + segments | `render_chrome.go:184` `renderStatusSegments` | modeline command zone → execute_command `semantic_mouse.go:87`, `events.go:79` | commands_test TestDecodeStatusChrome, TestDecodeStatusModelineSegments; model_test TestFooterRendersStatusMessageWithModelineSegments | PASS |
| Git status | gui_git_status 0x85 | `chrome_editor.go:426` `decodeGitStatus` | summarized in breadcrumb/footer `render_chrome.go:241` `gitSummary` | git file actions not routed (no git panel UI) | commands_test TestDecodeThemeAndEverydayChrome | DIVERGENCE: Go shows a compact git summary, not an interactive status panel; staging/commit happen through commands and key_press. |
| Search state | gui_search_state 0x9E | `chrome_editor.go:496` `decodeSearchState` | footer counter `render_chrome.go:164` | search nav via key_press | commands_test TestDecodeThemeAndEverydayChrome | PASS |
| Change summary | gui_change_summary 0x89 | `chrome_editor.go:512` `decodeChangeSummary` | footer counter `render_chrome.go:167` | change_summary_click not routed | commands_test TestDecodeThemeAndEverydayChrome | DIVERGENCE: surfaced as a footer count; full diff review is a GUI affordance, terminal uses buffers. |
| Which-key | gui_which_key 0x72 | `chrome_overlays.go:40` `decodeWhichKey` | `which_key_overlay.go:16` floating popup, `render_chrome.go:285` fallback | keyboard chord via key_press | generated_decode_test; model_test TestWhichKeyRendersCompactFloatingPopup, TestWhichKeyStylesGroupsAndLimitsColumnCount | PASS |
| Completion | gui_completion 0x73 | `chrome_overlays.go:5` `decodeCompletion`, generated tail decode | `render_chrome.go:277` `renderCompletion` | completion_select not routed; keyboard select via key_press | generated_decode_test TestDecodeGuiCompletionFieldsWithItems, TestDecodeHiddenCompletionSkipsTail; commands_test | PASS (see gap G6 for mouse select) |
| Minibuffer | gui_minibuffer 0x7F | `chrome_editor.go:152` `decodeMinibuffer` | `render_chrome.go:265` `renderMinibuffer` | keyboard via key_press; minibuffer_select not routed by mouse | commands_test TestDecodeMinibufferChrome | PASS |
| Picker | gui_picker 0x77 | `chrome_editor.go`/`chrome_overlays.go:83` `decodePicker` (6 sections) | `picker_overlay.go:15` floating layer, `render_chrome.go:301` `renderPicker` | keyboard via key_press | generated_decode_test (header/items/actions/load); model_test TestFloatingPicker..., TestPickerSelectedRowUsesSelectionColors, TestWidePickerPreviewRendersBesideList | PASS |
| Picker preview | gui_picker_preview 0x7D | `chrome_overlays.go:216` `decodePickerPreview` | `render_chrome.go:435` `renderPickerPreview`, side-by-side at width >= 100 | n/a | commands_test TestDecodePickerPreview...; model_test TestPickerPreviewRendersWithPicker, TestPickerPreviewDefaultsToPopupTextAndSurface | PASS |
| File tree | gui_file_tree 0x93 | `chrome_editor.go:187` `decodeFileTree` + rows | `render_content.go:702` `renderFileTree`, composited left via `withFileTree` (width >= 50) | row click → file_tree_click `semantic_mouse.go:121`, `events.go:71` | commands_test TestDecodeFileTreeChromeRows; model_test TestFileTreeSelectedRow..., TestFileTreeWidthRespectsProtocolGeometry... | PASS |
| File tree selection | gui_file_tree_selection 0x94 | `chrome_misc.go:85` `decodeFileTreeSelection` | applied to tree state `model.go:220` | n/a | model_test TestFileTreeSelectionUpdatesExistingTree | PASS |
| Sidebars | gui_sidebars 0x9F | `chrome_panels.go:319` `decodeSidebars` | `render_content.go:617` `withSemanticSidebars` (width >= 60) | sidebar_action not routed (label list only) | commands_test TestDecodePanelAndSidebarChrome; model_test TestSemanticWindowsRespectSidebarOffset | PASS for display; see gap G6 for sidebar host actions |
| Window content | gui_window_content 0x80 | `commands.go:260` `decodeWindowContent` (9 sections) | `render_content.go:196` `renderWindowRows`/`renderRow` | editor keys via key_press; raw mouse fallback `input.go:150` | commands_test TestDecodeWindowContentRows, TestDecodeWindowCursorlineSection; many model_test window cases | PASS |
| Window viewport delta | gui_window_viewport_delta 0xA1 | `commands.go:201` → `decodeWindowContent` | epoch-guarded merge `model.go:244` `applyWindowDelta` | n/a | commands_test TestDecodeWindowRowsAndViewportDeltas...; model_test TestApplyWindowDelta... | PASS |
| Window rows delta | gui_window_rows_delta 0xA2 | `commands.go:201` → `decodeWindowContent` | row-ref resolution `model.go:306` `resolveWindowRows` | n/a | commands_test TestDecodeWindowRowsAndViewportDeltas...; model_test TestApplyWindowDeltaResolvesRefs..., InvalidatesMissingRetainedRowRef | PASS |
| Window overlay delta | gui_window_overlay_delta 0xA0 | `commands.go:316` `decodeOverlayDelta` | cursor/cursorline merge `model.go:244` | n/a | commands_test TestDecodeWindowOverlaySections; model_test TestOverlayDeltaPreservesExistingScrollLeft | PASS |
| Gutter (line numbers, signs, folds) | gui_gutter 0x7B | `chrome_gutter.go:5` `decodeGutter` (3 sections) | `render_content.go:649` `renderGutterEntry` | fold_toggle_at_line not routed by mouse | commands_test TestDecodeGutterChrome; model_test TestApplyCommandsStoresSemanticGuttersByWindow, ...RendersGutterCursorline... | PASS (see gap G6 for gutter fold click) |
| Gutter separator | gui_gutter_sep 0x79 | `chrome_editor.go:536` `decodeGutterSeparator` | folded into gutter geometry | n/a | semantic_guardrail_test | DIVERGENCE: Go derives separators from gutter width rather than a discrete glyph column. |
| Cursorline | gui_cursorline 0x7A | `chrome_misc.go:47` `decodeCursorlineChrome` | `render_content.go:431` `withLegacyCursorline` and per-row bg | n/a | model_test TestLegacyCursorlineAppliesToCellFallback | PASS |
| Indent guides | gui_indent_guides 0x91 | `chrome_misc.go:58` `decodeIndentGuides` | `semantic_state.go:26` `applyIndentGuide` | n/a | model_test TestApplyCommandsStoresIndentGuidesByWindow, TestSemanticRowsRespectScrollLeftAndIndentGuides | PASS |
| Split separators | gui_split_separators 0x84 | `chrome_editor.go:544` `decodeSplitSeparators` | `render_content.go:445` `withSplitSeparators` | n/a | model_test TestSplitSeparatorsRenderOnContent, ...NormalizeAgainstHeaderAndFileTree | PASS |
| Hover popup | gui_hover_popup 0x81 | `chrome_overlays.go:253` `decodeHoverPopup` | `render_surfaces.go:56` `renderHover` | hover_open_action not routed by mouse | commands_test TestDecodeTransientOverlayChrome; model_test TestOverlayLinesRenderRemainingSemanticSurfaces | PASS |
| Hover action | gui_hover_action 0x96 | `chrome_overlays.go:286` `decodeHoverAction` | appended in `renderHover` `render_surfaces.go:63` | hover_open_action not routed by mouse | semantic_guardrail_test | PASS for display; see gap G6 |
| Signature help | gui_signature_help 0x82 | `chrome_overlays.go:301` `decodeSignatureHelp` | `render_surfaces.go:69` `renderSignature` | n/a | commands_test TestDecodeTransientOverlayChrome | PASS |
| Float popup | gui_float_popup 0x83 | `chrome_overlays.go:362` `decodeFloatPopup` | `render_surfaces.go:86` `renderFloat` | keyboard via key_press | commands_test TestDecodeTransientOverlayChrome | PASS |
| Agent context | gui_agent_context 0x88 | `chrome_agent.go:9` `decodeAgentContext` | `render_surfaces.go:99` `renderAgentContext` | agent_approve/request_changes/dismiss not routed by mouse | commands_test TestDecodeRemainingSemanticChrome | PASS for display; see gap G6 |
| Agent chat | gui_agent_chat 0x78 | `chrome_agent.go:26` `decodeAgentChat` (header/prompt/messages/pending/completion/styled) | `agent_chat_panel.go:24`, body takeover `render_content.go:16` | prompt typed via key_press; agent_tool_toggle not routed by mouse | commands_test TestDecodeAgentChatPreservesStructuredMessageDetails; model_test TestAgentChatPanelRendersStructuredTranscript, TestAgentAnimationCueChangesAcrossFrames | PASS |
| Edit timeline | gui_edit_timeline 0x9B | `chrome_agent.go:346` `decodeEditTimeline` | `render_surfaces.go:269` `renderEditTimeline` (table) | timeline_navigate not routed by mouse | commands_test TestDecodeAgentTimelineChrome | PASS for display; see gap G6 |
| Bottom panel | gui_bottom_panel 0x7C | `chrome_panels.go:115` `decodeBottomPanel` | `render_surfaces.go:138` `renderBottomPanel` | wheel scroll handled locally `semantic_mouse.go:30`; panel_switch_tab/resize/dismiss not routed by mouse | commands_test; model_test TestBottomPanelShowsLatestMessages..., TestBottomPanelWheelScrollIsHandledLocally, TestBottomPanelChromeUpdateClampsAndResetsScrollback | PASS for display + scroll; see gap G6 |
| Extension panel | gui_extension_panel 0x9D | `chrome_panels.go:167` `decodeExtensionPanel` (block kinds 0-6) | `render_surfaces.go:238` `renderExtensionPanels` | extension_panel_action / extension_action not routed | commands_test TestDecodePanelAndSidebarChrome | PASS for display; see gap G6 |
| Extension overlay | gui_extension_overlay 0x9C | `chrome_panels.go:9` `decodeExtensionOverlay` | `render_surfaces.go:294` `renderExtensionOverlay` | n/a | commands_test TestDecodePanelAndSidebarChrome | PASS |
| Extension runtime | gui_extension_runtime 0xA3 | decoded `commands.go:452` `decodeExtensionRuntime` | not consumed: `model.go:179` `applyCommands` has no `CommandExtensionRuntime` case, so it is silently dropped | n/a | protocol decode tested `extension_runtime_test.go`; no UI test | GAP (G1) |
| Observatory | gui_observatory 0x9A | `chrome_panels.go:367` `decodeObservatory` (2 sections) | `render_surfaces.go:256` `renderObservatory` (table) | observatory_inspect not routed by mouse | commands_test TestDecodePanelAndSidebarChrome | PASS for display; see gap G6 |
| Notifications | gui_notifications 0x99 | `chrome_panels.go:48` `decodeNotifications` | `render_surfaces.go:286` `renderNotifications` | notification_dismiss/action not routed | commands_test TestDecodeTransientOverlayChrome | DIVERGENCE: spec says TUI may skip this opcode (GUI_PROTOCOL.md:977); Go renders a compact list anyway. Inline action buttons are gap G6. |
| Tool manager | gui_tool_manager 0x7E | `chrome_misc.go:122` `decodeToolManager` | `render_surfaces.go:111` `renderToolManager` | tool_install/uninstall/update/dismiss not routed by mouse | semantic_guardrail_test | PASS for display; see gap G6 |
| Line spacing | gui_line_spacing 0x92 | `chrome_misc.go:106` `decodeLineSpacing` | none | n/a | semantic_guardrail_test | N/A: terminal cells have fixed height; no sub-cell line spacing. Decoded so it cannot desync the batch. |
| Cursor animation | gui_cursor_animation 0x95 | `chrome_misc.go:98` `decodeCursorAnimation` | none | n/a | semantic_guardrail_test | N/A: terminal cursor animation is owned by the terminal emulator. |
| Config state | gui_config_state 0x97 | `chrome_misc.go:114` `decodeConfigState` | none | config_update/query not routed | semantic_guardrail_test | N/A: native Settings UI is a GUI affordance; terminal users edit config files. |

## Input behaviors

| Behavior | Evidence | Status |
|---|---|---|
| Keyboard routing (printable, ctrl-letter, enter/esc/tab/backspace, arrows, space) | `input.go:13` `keyPacket`, encoded via `events.go:54` `EncodeKeyPress` | PASS. input_test TestKeyPacketPreservesCtrlLetter, EncodesSpace, EncodesPrintableUppercaseWithoutShiftModifier, PreservesNavigationModifiers |
| Modifier mapping (shift/ctrl/alt) | `input.go:136` `keyModifiers`, `input.go:128` `printableTextModifiers` | PASS. Shift is folded into the codepoint for printable text, matching BEAM expectations. input_test covers it. |
| Paste (bracketed paste and multi-rune key text) | `input.go:54` `pastePacket`, `input.go:49` fallback to `EncodePaste`, `events.go:88` | PASS. input_test TestPastePacketEncodesBracketedPasteAsPasteEvent, TestKeyPacketEncodesLoggedInsertSentence |
| Resize | `model.go:99` WindowSizeMsg → `EncodeResize` `events.go:50` | PASS |
| Ready handshake / capabilities | `main.go:31` sends `EncodeReady`; `events.go:33` reports frontend_type=tui, semantic_ui=true | PASS. commands_test TestEncodeReadyReportsSemanticTUI |
| Mouse: raw fallback (click/release/motion, all buttons, wheel up/down/left/right) | `input.go:150` `mousePacket`, `EncodeMouseEvent` `events.go:59` | PASS. input_test TestMousePacketEncodesHorizontalWheel |
| Mouse: SGR tail parsing from fragmented key text | `input.go:58` `sgrMouseTailPacket` | PASS. input_test TestKeyPacketParsesFragmentedSGRMouseTail, ...ShiftWheelSGRMouseTailAsHorizontal |
| Mouse: semantic click routing (tab, file tree row, modeline command) | `semantic_mouse.go:70` `semanticMousePacket` using lipgloss zones | PASS. model_test TestSemanticMouseRoutesModelineAndFileTreeZones |
| Mouse: local wheel scroll inside bottom panel | `semantic_mouse.go:30` `localMouse` | PASS. model_test TestBottomPanelWheelScrollIsHandledLocally, ...OutsidePanelFallsThrough |
| Mouse: semantic click routing for other chrome (breadcrumb, completion, picker rows, git files, notification actions, sidebars, gutter folds, panel tabs, agent buttons) | only tab, file tree, modeline command have zones in `semantic_mouse.go`; everything else falls through to raw `mousePacket` | GAP (G6) |
| Mouse: drag / multi-click (double, triple) | no click-count tracking; `EncodeMouseEvent` always sends click_count=1 (`input.go:80`, `:184`); no drag intent for tab_reorder or file_tree_drop | GAP (G2) |
| Clipboard write (OSC 52) | `model.go:207` CommandClipboardWrite → `model.go:153` emits `ansi.SetClipboard`; decode `commands.go:435` | PASS. Decode covered; OSC 52 emission is straightforward in View. |
| Clipboard read | no `cmd_copy`/`cmd_cut` handling; copy/cut go through editor key_press to the BEAM | DIVERGENCE: terminal copy is the editor's job via key_press; the macOS menu copy/cut actions are GUI-only. |
| Focus transitions (window focus, panel focus) | focus flags decoded per window/sidebar/tree; no terminal focus-in/out reporting emitted | DIVERGENCE: a single terminal surface has no multi-pane OS focus events; focus is BEAM-driven. |

## Gaps

### G1. Extension runtime envelope is decoded but dropped (non-blocking)

`gui_extension_runtime` (0xA3) decodes cleanly at the protocol layer (`commands.go:452`, tested in `extension_runtime_test.go`) but `model.go:179` `applyCommands` has no `CommandExtensionRuntime` case, so the payload is parsed and thrown away. The BEAM defines `encode_gui_extension_runtime/3` (`lib/minga_editor/frontend/protocol/gui.ex:878`) but I found no live production caller wiring it to a frontend, so this is currently latent rather than a visible regression. Blocking: no. This only matters once an extension actually ships a terminal runtime surface.

### G2. No mouse drag or multi-click (non-blocking)

Go always sends `click_count = 1` and has no drag tracking (`input.go:80`, `input.go:184`). The spec defines drag-driven actions: `tab_reorder` (0x48), `file_tree_drop` (0x40), and `scroll_to_line` from scroll-indicator drag (0x2F). Double/triple click for word/line selection also has no client-side handling. In practice the editor still receives raw press/release/motion events and the BEAM can synthesize selection from them, so the editor is usable; the loss is the polished drag affordances. Blocking: no (cosmetic interaction polish).

### G6. Mouse click routing is limited to three regions (non-blocking)

Only tab, file tree row, and modeline command zones are wired in `semantic_mouse.go:70`. Every other clickable chrome surface the spec lists a `gui_action` for (breadcrumb_click, completion_select, minibuffer_select, change_summary_click, git file stage/open, notification_dismiss/action, sidebar_action, observatory_inspect, timeline_navigate, tool manager actions, bottom panel tab switch/dismiss/resize, agent approve/request/dismiss/tool_toggle, hover_open_action, gutter fold_toggle) falls through to a raw mouse event rather than a semantic action. This is consistent and not broken: each of these surfaces is also reachable from the keyboard, which Go forwards as `key_press` and the BEAM handles. So the terminal is fully operable; what is missing is point-and-click convenience on secondary chrome. Blocking: no (mouse convenience, keyboard parity holds).

There are no GAP rows that block the flip. Every blocking-tier surface (window content and deltas, gutter, theme, tabs, status/modeline, picker, completion, which-key, file tree, agent chat, split separators, indent guides, keyboard, paste, resize, clipboard write, core mouse) is PASS.

## Flip-readiness recommendation

Ready to flip the default to Go.

All semantic surfaces that a terminal user depends on render correctly from the protocol, the full opcode set decodes under a build-failing guardrail, and the editor is fully operable by keyboard with core mouse routing for tabs, the file tree, and modeline commands. The remaining gaps (G1 extension runtime passthrough, G2 drag/multi-click, G6 click routing for secondary chrome) are interaction-polish and forward-compatibility items, not blockers: none of them prevents using the editor, and each has a working keyboard or raw-event path today.

Filed follow-up child tickets for #2216, ordered by value, all non-blocking:

1. #2230 "Go TUI routes semantic clicks for secondary chrome": scope: add lipgloss zones and `gui_action` encoders for breadcrumb, completion, picker rows, git files, notification actions, sidebars, bottom-panel tabs, and agent approve/dismiss so mouse users get parity with keyboard (closes G6).
2. #2229 "Go TUI supports mouse drag and multi-click selection": scope: track click_count and drag state in `input.go`, emit `tab_reorder`, `file_tree_drop`, `scroll_to_line`, and word/line selection on multi-click (closes G2).
3. #2228 "Go TUI consumes gui_extension_runtime envelopes": scope: add a `CommandExtensionRuntime` case in `applyCommands` and a routing surface so terminal extension runtimes render once the BEAM emits them (closes G1).
