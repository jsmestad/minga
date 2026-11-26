package ui

import (
	"strings"

	"charm.land/lipgloss/v2"
)

// Chrome tokens: the terminal twin of macos/Sources/Views/Shared/ChromeTokens.swift.
//
// Every step stores its macOS point value and converts to cells on read, so the conversion rule lives here once and the parity test in chrome_tokens_test.go can compare names and points with the Swift source. docs/design/anatomy.md owns the scale, the conversion rules and the part metrics; docs/CHARM_TUI.md#chrome-tokens explains how to use and extend them. This file is the only place in internal/ui where a spacing literal may appear (chrome_token_guardrail_test.go enforces that).
//
// Conversion, per anatomy.md "The scale on both frontends":
//   - Columns are floor(points / 8), with a minimum of 1 for any step of 4 pt or more, so a gap between two pieces of content never vanishes.
//   - Rows are floor(points / 18). Padding inside a row does not exist in the terminal.
//
// What collapses: pixel and hairline are zero cells; xs, sm, md and lg are one column; xl and xxl are two columns; everything up to xl is zero rows, and xxl, panel and section are one blank row. Radius accent, sm and md are square (a tinted block without a border); lg and xl are the rounded border. Typography collapses to a one-cell glyph or one of three text treatments: faint, normal and bold.

const (
	// cellWidthPoints is the width of one terminal cell at Minga's default font, in macOS points.
	cellWidthPoints = 8
	// cellHeightPoints is the height of one terminal cell at Minga's default font, in macOS points.
	cellHeightPoints = 18
)

// Declare every step as `name type = literal` (for example `spaceXS space = 4`): the parity test in chrome_tokens_test.go reads only explicitly typed literal constants, so a step written any other way would escape it.

// space is one step of the chrome spacing scale, stored in macOS points (Spacing in ChromeTokens.swift).
type space int

const (
	// spacePixel is optical separation. The TUI draws a glyph or a tint instead: 0 columns, 0 rows.
	spacePixel space = 1
	// spaceHairline is badge internals and tight vertical rhythm: 0 columns, 0 rows.
	spaceHairline space = 2
	// spaceXS is tight inline groups, such as a key and its label or a glyph and its word: 1 column, 0 rows.
	spaceXS space = 4
	// spaceSM is compact row gaps and chip padding: 1 column, 0 rows.
	spaceSM space = 6
	// spaceMD is default gaps and insets: 1 column, 0 rows.
	spaceMD space = 8
	// spaceLG is panel insets and label to meta: 1 column, 0 rows.
	spaceLG space = 12
	// spaceXL is between groups on one line, such as hints and chips: 2 columns, 0 rows.
	spaceXL space = 16
	// spaceXXL is between blocks of a panel: 2 columns, 1 row.
	spaceXXL space = 20
	// spacePanel is empty-state and dialog insets and the which-key column gap: 3 columns, 1 row.
	spacePanel space = 24
	// spaceSection is major section breaks: 4 columns, 1 row.
	spaceSection space = 32
)

// cols converts the step to terminal columns.
func (s space) cols() int {
	cols := int(s) / cellWidthPoints
	if cols == 0 && s >= spaceXS {
		return 1
	}
	return cols
}

// rows converts the step to terminal rows.
func (s space) rows() int {
	return int(s) / cellHeightPoints
}

// gap returns the step's columns as a run of spaces, so call sites never count spaces by hand.
func gap(s space) string {
	return strings.Repeat(" ", s.cols())
}

// padding returns Lip Gloss Padding or Margin arguments (rows, then columns) for a vertical and a horizontal step: style.Padding(padding(spaceHairline, spaceSM)).
func padding(vertical, horizontal space) (int, int) {
	return vertical.rows(), horizontal.cols()
}

// radius is one step of the chrome corner scale, stored in macOS points (Radius in ChromeTokens.swift).
type radius int

const (
	// radiusAccent is a narrow active-row accent: square.
	radiusAccent radius = 1
	// radiusSM is compact rows, badges and fields: square.
	radiusSM radius = 4
	// radiusMD is small panels and controls: square.
	radiusMD radius = 6
	// radiusLG is overlays and cards: the rounded border.
	radiusLG radius = 8
	// radiusXL is large cards and prompt capsules: the rounded border.
	radiusXL radius = 12
)

// border returns the Lip Gloss border for the step, and false when the step is square and draws no border.
func (r radius) border() (lipgloss.Border, bool) {
	if r >= radiusLG {
		return lipgloss.RoundedBorder(), true
	}
	return lipgloss.Border{}, false
}

// textStep is one chrome typography step, stored in macOS points (Typography.Step in ChromeTokens.swift).
type textStep int

const (
	textTiny         textStep = 7
	textSymbol       textStep = 8
	textMicro        textStep = 9
	textCaption      textStep = 10
	textSmall        textStep = 11
	textBody         textStep = 12
	textEmphasis     textStep = 13
	textTitle        textStep = 14
	textToolbar      textStep = 15
	textHeading      textStep = 16
	textIllustration textStep = 20
	textAction       textStep = 24
)

// textTreatment is what a typography step becomes in a terminal with one text size.
type textTreatment int

const (
	// treatmentGlyph is a one-cell glyph.
	treatmentGlyph textTreatment = iota
	// treatmentFaint is the text.faint colour role.
	treatmentFaint
	// treatmentNormal is plain text.
	treatmentNormal
	// treatmentBold is bold text.
	treatmentBold
)

// treatment returns the step's TUI treatment, per the anatomy.md text table.
func (t textStep) treatment() textTreatment {
	switch {
	case t <= textMicro:
		return treatmentGlyph
	case t == textCaption:
		return treatmentFaint
	case t <= textBody:
		return treatmentNormal
	case t <= textHeading:
		return treatmentBold
	default:
		return treatmentGlyph
	}
}

// style returns the step's text treatment as a Lip Gloss style. Colours come from palette roles, never literals.
func (t textStep) style(p palette) lipgloss.Style {
	style := lipgloss.NewStyle()
	switch t.treatment() {
	case treatmentFaint:
		return style.Foreground(p.TextFaint())
	case treatmentBold:
		return style.Bold(true)
	default:
		return style
	}
}

// Part metrics: one block per part in docs/design/anatomy.md, named by part. Gaps and insets are space steps (convert with cols() or rows(), or render with gap()); row counts are terminal rows; corners are radius steps. When the TUI column of anatomy.md departs from the conversion rule, the metric holds the TUI value and says why.

// Drawer: a real split along the bottom of the window.
const (
	drawerDivider       = spacePixel
	drawerHeaderInset   = spaceLG
	drawerTitleToCounts = spaceMD
	drawerKeyToHint     = spaceXS
	drawerHintToHint    = spaceXL
	drawerBodyInset     = spaceLG
	drawerBodyTopInset  = spaceSM
	drawerTitleText     = textEmphasis
	drawerHintText      = textSmall
)

// List row: one row of a list buffer (tasks, review, diagnostics, the switcher, quickfix).
const (
	listRowRows            = 1
	listRowSelectionEdge   = radiusAccent // ▌ in the row's role colour, column 0
	listRowSelectionCorner = radiusSM     // full-width bar
	listRowGlyphToTitle    = spaceSM
	listRowTitleToMeta     = spaceXL // minimum
	listRowTrailingInset   = spaceLG
	listRowTitleText       = textBody
	listRowMetaText        = textSmall
)

// Section label with rule: groups inside a menu, a hover or a long list.
const (
	sectionLabelText       = textCaption
	sectionLabelToRule     = spaceMD
	sectionLabelRule       = spacePixel // ─ in the quiet border colour, to the border
	sectionLabelSpaceAbove = spaceXL
	sectionLabelSpaceBelow = spaceXS
)

// Decision bar: two equal halves asking a yes or no question.
const (
	decisionBarInset              = spaceMD
	decisionBarHalfGap            = spaceXS
	decisionBarHalfCorner         = radiusMD
	decisionBarHalfPadding        = spaceSM // vertical
	decisionBarKeyToLabel         = spaceSM
	decisionBarLabelToConsequence = spaceHairline // the consequence takes the next row
	decisionBarRows               = 2             // label row plus consequence row
	decisionBarLabelText          = textEmphasis
	decisionBarConsequenceText    = textCaption
)

// Popover and menu: the act menu and any compact panel at a target.
const (
	popoverCorner             = radiusLG
	popoverHeaderToFirstBlock = spaceMD
	popoverRowRows            = 1
	popoverRowInset           = spaceMD
	popoverKeyColumnGap       = spaceMD // the key column is the widest key plus this gap
	popoverLabelToDirectKey   = spaceXL // minimum, direct key right-aligned
	popoverVerticalPadding    = spaceXS
	popoverMinCols            = 36
	popoverMaxCols            = 64
	popoverLabelText          = textBody
)

// Which-key panel: one panel anchored above the modeline.
const (
	whichKeyCorner       = radiusLG
	whichKeyMarginCols   = 0 // anatomy.md: md on macOS, full width in the TUI
	whichKeyInsetH       = spaceLG
	whichKeyInsetV       = spaceMD
	whichKeyColumnGap    = spacePanel
	whichKeyGroupToEntry = spaceXS
	whichKeyEntryRows    = 1
	whichKeyKeyToLabel   = spaceMD // inside a fixed key column
	whichKeyLabelToCount = spaceMD
	whichKeyGroupText    = textCaption
	whichKeyLabelText    = textBody
)

// Modeline segments.
const (
	modelineInset        = spaceSM
	modelineSegmentGap   = spaceMD
	modelineGlyphToWords = spaceXS
	modelinePillPaddingH = spaceSM
	modelinePillPaddingV = spaceHairline
	modelinePillCorner   = radiusSM // square, reverse video
	modelineText         = textSmall
)

// Prompt and minibuffer: the command line, confirmations and the query row of a picker.
const (
	promptInset           = spaceSM
	promptLabelToQuery    = spaceMD
	promptChipPaddingCols = 0 // anatomy.md: sm on macOS, the key is a reverse-video cell in the TUI
	promptChipCorner      = radiusSM
	promptChipKeyToLabel  = spaceXS
	promptChipToChip      = spaceXL
	promptQueryToResults  = spaceXS
	promptLabelText       = textBody
)

// Empty state: every empty state and every notice with actions.
const (
	emptyStateInset         = spacePanel
	emptyStateGlyphToTitle  = spaceSM
	emptyStateTitleToWhy    = spaceXS
	emptyStateWhyToActions  = spaceXXL
	emptyStateActionRows    = 1
	emptyStateKeyColumnGap  = spaceLG // the key column is the widest key plus this gap
	emptyStateTitleText     = textEmphasis
	emptyStateWhyText       = textBody
	emptyStateActionKeyText = textSmall
)

// Notice: a message in the echo line, with optional actions.
const (
	noticeInset           = spaceSM
	noticeMessageToAction = spaceMD // on each side of a ·
	noticeActionToAction  = spaceMD // on each side of a ·
	noticeKeyToAction     = spaceXS
	noticeText            = textBody
)

// Hover popover: K and the pointer resting on a target.
const (
	hoverCorner      = radiusLG
	hoverInsetH      = spaceLG
	hoverInsetV      = spaceMD
	hoverOffset      = spaceXS // the next free row, never over the cursor line
	hoverSectionGap  = spaceMD // a ─ row
	hoverMaxCols     = 72
	hoverMaxRows     = 12
	hoverFooterText  = textCaption
	hoverHeadingText = textBody
)

// Cell facts that are not spacing.
const (
	// wideGlyphCols is the width of a double-width glyph, such as many Nerd Font icons. A glyph slot this wide keeps the text after it in one column.
	wideGlyphCols = 2
)

// Interim metrics for surfaces whose anatomy part has not landed yet. Each keeps today's cells by choosing the step that converts to them; the surface's own ticket replaces it with an anatomy part.
const (
	// agentTranscriptInset is the two columns before a transcript marker or rail (❯, ◇, │, ├─), kept clear after a row's text at the right edge as well.
	agentTranscriptInset = spaceXL
	// agentTranscriptBodyIndent indents a user message body and the turn separator under the speaker label.
	agentTranscriptBodyIndent = spaceSection

	// Queue header and row spacing inside the conversation column.
	agentQueueInset     = spaceMD
	agentQueueHeaderGap = spaceXL
	agentQueueHintGap   = spaceXS
)
