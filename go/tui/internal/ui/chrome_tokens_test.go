package ui

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"

	"charm.land/lipgloss/v2"
)

// chromeTokensSwift is the macOS source of truth for the scale.
const chromeTokensSwift = "../../../../macos/Sources/Views/Shared/ChromeTokens.swift"

func TestChromeTokenScaleConvertsEachSpacingStep(t *testing.T) {
	steps := []struct {
		name       string
		step       space
		cols, rows int
	}{
		{"pixel", spacePixel, 0, 0},
		{"hairline", spaceHairline, 0, 0},
		{"xs", spaceXS, 1, 0},
		{"sm", spaceSM, 1, 0},
		{"md", spaceMD, 1, 0},
		{"lg", spaceLG, 1, 0},
		{"xl", spaceXL, 2, 0},
		{"xxl", spaceXXL, 2, 1},
		{"panel", spacePanel, 3, 1},
		{"section", spaceSection, 4, 1},
	}
	for _, step := range steps {
		if got := step.step.cols(); got != step.cols {
			t.Errorf("%s (%d pt) is %d columns, want %d", step.name, step.step, got, step.cols)
		}
		if got := step.step.rows(); got != step.rows {
			t.Errorf("%s (%d pt) is %d rows, want %d", step.name, step.step, got, step.rows)
		}
		if got := gap(step.step); got != strings.Repeat(" ", step.cols) {
			t.Errorf("gap(%s) = %q, want %d spaces", step.name, got, step.cols)
		}
	}
	if vertical, horizontal := padding(spaceXXL, spacePanel); vertical != 1 || horizontal != 3 {
		t.Errorf("padding(xxl, panel) = (%d, %d), want (1, 3)", vertical, horizontal)
	}
}

func TestChromeTokenScaleConvertsEachRadiusStep(t *testing.T) {
	steps := []struct {
		name    string
		step    radius
		rounded bool
	}{
		{"accent", radiusAccent, false},
		{"sm", radiusSM, false},
		{"md", radiusMD, false},
		{"lg", radiusLG, true},
		{"xl", radiusXL, true},
	}
	for _, step := range steps {
		border, ok := step.step.border()
		if ok != step.rounded {
			t.Errorf("radius %s draws a border: %t, want %t", step.name, ok, step.rounded)
		}
		if ok && border != lipgloss.RoundedBorder() {
			t.Errorf("radius %s must use the rounded border", step.name)
		}
	}
}

func TestChromeTokenScaleConvertsEachTypographyStep(t *testing.T) {
	steps := []struct {
		name string
		step textStep
		want textTreatment
	}{
		{"tiny", textTiny, treatmentGlyph},
		{"symbol", textSymbol, treatmentGlyph},
		{"micro", textMicro, treatmentGlyph},
		{"caption", textCaption, treatmentFaint},
		{"small", textSmall, treatmentNormal},
		{"body", textBody, treatmentNormal},
		{"emphasis", textEmphasis, treatmentBold},
		{"title", textTitle, treatmentBold},
		{"toolbar", textToolbar, treatmentBold},
		{"heading", textHeading, treatmentBold},
		{"illustration", textIllustration, treatmentGlyph},
		{"action", textAction, treatmentGlyph},
	}
	p := bootstrapPalette()
	for _, step := range steps {
		if got := step.step.treatment(); got != step.want {
			t.Errorf("%s is treatment %d, want %d", step.name, got, step.want)
		}
	}
	if !textHeading.style(p).GetBold() || textBody.style(p).GetBold() {
		t.Error("only bold steps render bold")
	}
	if textCaption.style(p).GetForeground() != p.TextFaint() {
		t.Error("caption renders in the text.faint role")
	}
}

// TestChromeTokenPartMetricsMatchAnatomy checks each part metric against the TUI column of docs/design/anatomy.md.
func TestChromeTokenPartMetricsMatchAnatomy(t *testing.T) {
	square := func(r radius) int {
		if _, ok := r.border(); ok {
			return 1
		}
		return 0
	}
	metrics := []struct {
		name      string
		got, want int
	}{
		{"drawerDivider cols", drawerDivider.cols(), 0},
		{"drawerHeaderInset cols", drawerHeaderInset.cols(), 1},
		{"drawerTitleToCounts cols", drawerTitleToCounts.cols(), 1},
		{"drawerKeyToHint cols", drawerKeyToHint.cols(), 1},
		{"drawerHintToHint cols", drawerHintToHint.cols(), 2},
		{"drawerBodyInset cols", drawerBodyInset.cols(), 1},
		{"drawerBodyTopInset rows", drawerBodyTopInset.rows(), 0},
		{"drawerTitleText", int(drawerTitleText.treatment()), int(treatmentBold)},
		{"drawerHintText", int(drawerHintText.treatment()), int(treatmentNormal)},

		{"listRowRows", listRowRows, 1},
		{"listRowSelectionEdge border", square(listRowSelectionEdge), 0},
		{"listRowSelectionCorner border", square(listRowSelectionCorner), 0},
		{"listRowGlyphToTitle cols", listRowGlyphToTitle.cols(), 1},
		{"listRowTitleToMeta cols", listRowTitleToMeta.cols(), 2},
		{"listRowTrailingInset cols", listRowTrailingInset.cols(), 1},
		{"listRowTitleText", int(listRowTitleText.treatment()), int(treatmentNormal)},
		{"listRowMetaText", int(listRowMetaText.treatment()), int(treatmentNormal)},

		{"sectionLabelText", int(sectionLabelText.treatment()), int(treatmentFaint)},
		{"sectionLabelToRule cols", sectionLabelToRule.cols(), 1},
		{"sectionLabelRule cols", sectionLabelRule.cols(), 0},
		{"sectionLabelSpaceAbove rows", sectionLabelSpaceAbove.rows(), 0},
		{"sectionLabelSpaceBelow rows", sectionLabelSpaceBelow.rows(), 0},

		{"decisionBarInset cols", decisionBarInset.cols(), 1},
		{"decisionBarHalfGap cols", decisionBarHalfGap.cols(), 1},
		{"decisionBarHalfCorner border", square(decisionBarHalfCorner), 0},
		{"decisionBarHalfPadding rows", decisionBarHalfPadding.rows(), 0},
		{"decisionBarKeyToLabel cols", decisionBarKeyToLabel.cols(), 1},
		{"decisionBarLabelToConsequence rows", decisionBarLabelToConsequence.rows(), 0},
		{"decisionBarRows", decisionBarRows, 2},
		{"decisionBarLabelText", int(decisionBarLabelText.treatment()), int(treatmentBold)},
		{"decisionBarConsequenceText", int(decisionBarConsequenceText.treatment()), int(treatmentFaint)},

		{"popoverCorner border", square(popoverCorner), 1},
		{"popoverHeaderToFirstBlock rows", popoverHeaderToFirstBlock.rows(), 0},
		{"popoverRowRows", popoverRowRows, 1},
		{"popoverRowInset cols", popoverRowInset.cols(), 1},
		{"popoverKeyColumnGap cols", popoverKeyColumnGap.cols(), 1},
		{"popoverLabelToDirectKey cols", popoverLabelToDirectKey.cols(), 2},
		{"popoverVerticalPadding rows", popoverVerticalPadding.rows(), 0},
		{"popoverMinCols", popoverMinCols, 36},
		{"popoverMaxCols", popoverMaxCols, 64},
		{"popoverLabelText", int(popoverLabelText.treatment()), int(treatmentNormal)},

		{"whichKeyCorner border", square(whichKeyCorner), 1},
		{"whichKeyMarginCols", whichKeyMarginCols, 0},
		{"whichKeyInsetH cols", whichKeyInsetH.cols(), 1},
		{"whichKeyInsetV rows", whichKeyInsetV.rows(), 0},
		{"whichKeyColumnGap cols", whichKeyColumnGap.cols(), 3},
		{"whichKeyGroupToEntry rows", whichKeyGroupToEntry.rows(), 0},
		{"whichKeyEntryRows", whichKeyEntryRows, 1},
		{"whichKeyKeyToLabel cols", whichKeyKeyToLabel.cols(), 1},
		{"whichKeyLabelToCount cols", whichKeyLabelToCount.cols(), 1},
		{"whichKeyGroupText", int(whichKeyGroupText.treatment()), int(treatmentFaint)},
		{"whichKeyLabelText", int(whichKeyLabelText.treatment()), int(treatmentNormal)},

		{"modelineInset cols", modelineInset.cols(), 1},
		{"modelineSegmentGap cols", modelineSegmentGap.cols(), 1},
		{"modelineGlyphToWords cols", modelineGlyphToWords.cols(), 1},
		{"modelinePillPaddingH cols", modelinePillPaddingH.cols(), 1},
		{"modelinePillPaddingV rows", modelinePillPaddingV.rows(), 0},
		{"modelinePillCorner border", square(modelinePillCorner), 0},
		{"modelineText", int(modelineText.treatment()), int(treatmentNormal)},

		{"promptInset cols", promptInset.cols(), 1},
		{"promptLabelToQuery cols", promptLabelToQuery.cols(), 1},
		{"promptChipPaddingCols", promptChipPaddingCols, 0},
		{"promptChipCorner border", square(promptChipCorner), 0},
		{"promptChipKeyToLabel cols", promptChipKeyToLabel.cols(), 1},
		{"promptChipToChip cols", promptChipToChip.cols(), 2},
		{"promptQueryToResults rows", promptQueryToResults.rows(), 0},
		{"promptLabelText", int(promptLabelText.treatment()), int(treatmentNormal)},

		{"emptyStateInset cols", emptyStateInset.cols(), 3},
		{"emptyStateInset rows", emptyStateInset.rows(), 1},
		{"emptyStateGlyphToTitle cols", emptyStateGlyphToTitle.cols(), 1},
		{"emptyStateTitleToWhy rows", emptyStateTitleToWhy.rows(), 0},
		{"emptyStateWhyToActions rows", emptyStateWhyToActions.rows(), 1},
		{"emptyStateActionRows", emptyStateActionRows, 1},
		{"emptyStateKeyColumnGap cols", emptyStateKeyColumnGap.cols(), 1},
		{"emptyStateTitleText", int(emptyStateTitleText.treatment()), int(treatmentBold)},
		{"emptyStateWhyText", int(emptyStateWhyText.treatment()), int(treatmentNormal)},
		{"emptyStateActionKeyText", int(emptyStateActionKeyText.treatment()), int(treatmentNormal)},

		{"noticeInset cols", noticeInset.cols(), 1},
		{"noticeMessageToAction cols", noticeMessageToAction.cols(), 1},
		{"noticeActionToAction cols", noticeActionToAction.cols(), 1},
		{"noticeKeyToAction cols", noticeKeyToAction.cols(), 1},
		{"noticeText", int(noticeText.treatment()), int(treatmentNormal)},

		{"hoverCorner border", square(hoverCorner), 1},
		{"hoverInsetH cols", hoverInsetH.cols(), 1},
		{"hoverInsetV rows", hoverInsetV.rows(), 0},
		{"hoverOffset rows", hoverOffset.rows(), 0},
		{"hoverSectionGap rows", hoverSectionGap.rows(), 0},
		{"hoverMaxCols", hoverMaxCols, 72},
		{"hoverMaxRows", hoverMaxRows, 12},
		{"hoverFooterText", int(hoverFooterText.treatment()), int(treatmentFaint)},
		{"hoverHeadingText", int(hoverHeadingText.treatment()), int(treatmentNormal)},
	}
	for _, metric := range metrics {
		if metric.got != metric.want {
			t.Errorf("%s = %d, want %d (docs/design/anatomy.md)", metric.name, metric.got, metric.want)
		}
	}
}

// TestChromeTokenScaleMatchesMacOS fails when a step exists on one frontend only, or when the two disagree about its points.
func TestChromeTokenScaleMatchesMacOS(t *testing.T) {
	source, err := os.ReadFile(chromeTokensSwift)
	if err != nil {
		t.Fatal(err)
	}
	swift := swiftChromeScales(t, string(source))
	for _, line := range swiftUnparsedSteps(string(source), swiftChromeScaleEnums...) {
		t.Errorf("ChromeTokens.swift declares a step the parity parser cannot read: %s", line)
	}
	goScales := goChromeScales(t, chromeTokenOwner)
	for _, scale := range []struct{ swiftEnum, goType string }{{"Spacing", "space"}, {"Radius", "radius"}, {"Step", "textStep"}} {
		want, got := swift[scale.swiftEnum], goScales[scale.goType]
		if len(want) == 0 {
			t.Errorf("ChromeTokens.swift has no %s steps; the parity parser is stale", scale.swiftEnum)
		}
		for _, name := range sortedKeys(want) {
			points, ok := got[name]
			switch {
			case !ok:
				t.Errorf("%s.%s exists on macOS only; add it to %s", scale.swiftEnum, name, chromeTokenOwner)
			case points != want[name]:
				t.Errorf("%s.%s is %d pt on macOS and %d pt in the TUI", scale.swiftEnum, name, want[name], points)
			}
		}
		for _, name := range sortedKeys(got) {
			if _, ok := want[name]; !ok {
				t.Errorf("%s %s exists in the TUI only; add it to ChromeTokens.swift", scale.goType, name)
			}
		}
	}
}

func TestChromeTokenParityParsersReadBothSources(t *testing.T) {
	swift := swiftChromeScales(t, "public enum Spacing {\n    public static let xs: CGFloat = 4\n}\npublic enum Typography {\n    public enum Step: CGFloat, Sendable {\n        case caption = 10\n    }\n    public static let monospacedSmall = font(.small)\n}\npublic enum Radius {\n    public static let lg: CGFloat = 8\n}\n")
	if swift["Spacing"]["xs"] != 4 || swift["Step"]["caption"] != 10 || swift["Radius"]["lg"] != 8 || len(swift["Typography"]) != 0 {
		t.Errorf("Swift parser read %v", swift)
	}
	for _, line := range []string{
		"    public static let xs: CGFloat = 4 // tight",
		"    public static var md: CGFloat = 8",
		"    static let lg = 12.0",
		"    public static let xl: Double = 16",
		"    nonisolated public static let panel: CGFloat = 24",
		"        case a = 1, b = 2",
		"        case heading",
	} {
		for _, enum := range swiftChromeScaleEnums {
			source := "public enum " + enum + " {\n" + line + "\n    public static func helper() -> CGFloat { 0 }\n}\n"
			if unparsed := swiftUnparsedSteps(source, enum); len(unparsed) != 1 || unparsed[0] != strings.TrimSpace(line) {
				t.Errorf("%s: unparsed step %q reported as %q", enum, line, unparsed)
			}
		}
	}
	strict := "public enum Spacing {\n    /// 4pt: tight.\n    public static let xs: CGFloat = 4\n    static let sm: CGFloat = 6\n}\npublic enum Typography {\n    public enum Step: CGFloat, Sendable {\n        case caption = 10\n    }\n    public static let monospacedSmall = font(.small)\n}\n"
	if unparsed := swiftUnparsedSteps(strict, swiftChromeScaleEnums...); len(unparsed) != 0 {
		t.Errorf("strict steps reported as unparsed: %q", unparsed)
	}
	if got := goTokenName("space", "spaceXXL"); got != "xxl" {
		t.Errorf("spaceXXL maps to %q, want xxl", got)
	}
	if got := goTokenName("text", "textIllustration"); got != "illustration" {
		t.Errorf("textIllustration maps to %q, want illustration", got)
	}
}

// swiftChromeScaleEnums are the ChromeTokens.swift enums whose steps the TUI mirrors: Spacing, Radius and Typography.Step.
var swiftChromeScaleEnums = []string{"Spacing", "Radius", "Step"}

var (
	swiftEnumPattern  = regexp.MustCompile(`enum (\w+)\b[^{]*\{`)
	swiftDeclPattern  = regexp.MustCompile(`(?m)^\s*(?:\w+\s+)*(?:static\s+(?:let|var)|case)\b.*$`)
	swiftStepPattern  = regexp.MustCompile(`(?m)^\s*(?:public )?static let (\w+): CGFloat = ([0-9.]+)\s*$|^\s*case (\w+) = ([0-9.]+)\s*$`)
	goScalePrefixes   = map[string]string{"space": "space", "radius": "radius", "textStep": "text"}
	goUppercaseSuffix = regexp.MustCompile(`^[A-Z]+$`)
)

// swiftChromeScales reads each enum's directly declared steps: `static let name: CGFloat = n` and `case name = n`, keyed by enum name.
func swiftChromeScales(t *testing.T, source string) map[string]map[string]int {
	t.Helper()
	scales := map[string]map[string]int{}
	for _, match := range swiftEnumPattern.FindAllStringSubmatchIndex(source, -1) {
		name := source[match[2]:match[3]]
		body := swiftDirectBody(source[match[1]:])
		steps := map[string]int{}
		for _, step := range swiftStepPattern.FindAllStringSubmatch(body, -1) {
			key, value := step[1], step[2]
			if key == "" {
				key, value = step[3], step[4]
			}
			points, err := strconv.ParseFloat(value, 64)
			if err != nil {
				t.Fatalf("%s.%s: %v", name, key, err)
			}
			steps[key] = int(points)
		}
		scales[name] = steps
	}
	return scales
}

// swiftUnparsedSteps returns each `static let`, `static var` or `case` line directly inside the named enums that swiftStepPattern does not read, so a step written another way fails parity instead of disappearing from it.
func swiftUnparsedSteps(source string, enums ...string) []string {
	wanted := map[string]bool{}
	for _, name := range enums {
		wanted[name] = true
	}
	var unparsed []string
	for _, match := range swiftEnumPattern.FindAllStringSubmatchIndex(source, -1) {
		if !wanted[source[match[2]:match[3]]] {
			continue
		}
		for _, line := range swiftDeclPattern.FindAllString(swiftDirectBody(source[match[1]:]), -1) {
			if !swiftStepPattern.MatchString(line) {
				unparsed = append(unparsed, strings.TrimSpace(line))
			}
		}
	}
	return unparsed
}

// swiftDirectBody returns the text of an enum body at nesting depth one, dropping nested type bodies.
func swiftDirectBody(source string) string {
	var body strings.Builder
	depth := 1
	for _, r := range source {
		switch r {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return body.String()
			}
		}
		if depth == 1 {
			body.WriteRune(r)
		}
	}
	return body.String()
}

// goChromeScales reads the constants in chrome_tokens.go declared with an explicit scale type and a literal point value, keyed by type and anatomy name.
func goChromeScales(t *testing.T, path string) map[string]map[string]int {
	t.Helper()
	file, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.SkipObjectResolution)
	if err != nil {
		t.Fatal(err)
	}
	scales := map[string]map[string]int{}
	for _, decl := range file.Decls {
		gen, ok := decl.(*ast.GenDecl)
		if !ok || gen.Tok != token.CONST {
			continue
		}
		for _, spec := range gen.Specs {
			value := spec.(*ast.ValueSpec)
			typ, ok := value.Type.(*ast.Ident)
			if !ok || goScalePrefixes[typ.Name] == "" || len(value.Values) != len(value.Names) {
				continue
			}
			for i, name := range value.Names {
				lit, ok := value.Values[i].(*ast.BasicLit)
				if !ok || lit.Kind != token.INT {
					continue
				}
				points, err := strconv.Atoi(lit.Value)
				if err != nil {
					t.Fatal(err)
				}
				if scales[typ.Name] == nil {
					scales[typ.Name] = map[string]int{}
				}
				scales[typ.Name][goTokenName(goScalePrefixes[typ.Name], name.Name)] = points
			}
		}
	}
	return scales
}

// goTokenName maps a Go identifier to its anatomy name: spaceXS is xs, spacePixel is pixel, textCaption is caption.
func goTokenName(prefix, identifier string) string {
	suffix := strings.TrimPrefix(identifier, prefix)
	if goUppercaseSuffix.MatchString(suffix) {
		return strings.ToLower(suffix)
	}
	return strings.ToLower(suffix[:1]) + suffix[1:]
}

func sortedKeys(values map[string]int) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}
