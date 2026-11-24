package ui

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// The terminal twin of ChromeTokenGuardrailTests on macOS: chrome spacing comes from chrome_tokens.go, never from a literal. See docs/CHARM_TUI.md#chrome-tokens.

// chromeTokenOwner owns the scale and is the one file allowed to hold spacing literals.
const chromeTokenOwner = "chrome_tokens.go"

// chromeTokenExclusions are editor-cell rendering files, the counterpart of Views/Editor on macOS. Buffer rows and gutters are measured in editor cells, not chrome tokens.
var chromeTokenExclusions = []struct{ path, reason string }{}

// chromeTokenAllowlist is the migration ratchet. It is empty and must stay empty; a stale or unexplained entry fails.
var chromeTokenAllowlist = []struct{ path, reason string }{}

// chromeStyleMethods are the Lip Gloss style methods whose arguments are chrome measurements.
var chromeStyleMethods = map[string]bool{
	"Padding": true, "PaddingTop": true, "PaddingRight": true, "PaddingBottom": true, "PaddingLeft": true,
	"Margin": true, "MarginTop": true, "MarginRight": true, "MarginBottom": true, "MarginLeft": true,
	"Width": true, "Height": true, "MaxWidth": true, "MaxHeight": true,
}

func TestChromeTokenGuardrailSourcesUseTheScale(t *testing.T) {
	excluded := map[string]bool{chromeTokenOwner: true}
	for _, entry := range chromeTokenExclusions {
		if strings.TrimSpace(entry.reason) == "" {
			t.Errorf("%s: exclusion reason is empty", entry.path)
		}
		if _, err := os.Stat(entry.path); err != nil {
			t.Errorf("%s: stale exclusion: %v", entry.path, err)
		}
		excluded[entry.path] = true
	}

	paths, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	found := map[string][]string{}
	for _, path := range paths {
		if strings.HasSuffix(path, "_test.go") || excluded[path] {
			continue
		}
		source, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		violations, err := chromeLiteralViolations(path, source)
		if err != nil {
			t.Fatal(err)
		}
		if len(violations) > 0 {
			found[path] = violations
		}
	}

	for _, failure := range chromeTokenRatchetFailures(found, chromeTokenAllowlist) {
		t.Error(failure)
	}
	if len(chromeTokenAllowlist) != 0 {
		t.Errorf("the chrome token allowlist must stay empty, has %d entries", len(chromeTokenAllowlist))
	}
}

func chromeTokenRatchetFailures(found map[string][]string, allowlist []struct{ path, reason string }) []string {
	var failures []string
	allowed := map[string]bool{}
	for _, entry := range allowlist {
		if strings.TrimSpace(entry.reason) == "" {
			failures = append(failures, entry.path+": allowlist reason is empty")
		}
		if allowed[entry.path] {
			failures = append(failures, entry.path+": duplicate allowlist entry")
		}
		allowed[entry.path] = true
		if _, ok := found[entry.path]; !ok {
			failures = append(failures, entry.path+": stale allowlist entry")
		}
	}
	paths := make([]string, 0, len(found))
	for path := range found {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	for _, path := range paths {
		if allowed[path] {
			continue
		}
		for _, violation := range found[path] {
			failures = append(failures, path+":"+violation)
		}
	}
	return failures
}

// chromeLiteralViolations reports each spacing literal in a Go source file as "line: reason: expression".
func chromeLiteralViolations(filename string, source []byte) ([]string, error) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, filename, source, parser.SkipObjectResolution)
	if err != nil {
		return nil, err
	}
	var violations []string
	report := func(node ast.Node, reason string) {
		start, end := fset.Position(node.Pos()), fset.Position(node.End())
		violations = append(violations, fmt.Sprintf("%d: %s: %s", start.Line, reason, source[start.Offset:end.Offset]))
	}
	tags := map[*ast.BasicLit]bool{}
	ast.Inspect(file, func(node ast.Node) bool {
		switch node := node.(type) {
		case *ast.ImportSpec:
			return false
		case *ast.Field:
			if node.Tag != nil {
				tags[node.Tag] = true
			}
		case *ast.CallExpr:
			switch {
			case isChromeStyleCall(node):
				for _, arg := range node.Args {
					if lit := spacingLiteral(arg); lit != nil {
						report(node, "spacing literal "+lit.Value+" in a Lip Gloss measurement")
					}
				}
			case isSpaceRepeat(node):
				if lit := spacingLiteral(node.Args[1]); lit != nil {
					report(node, "spacing literal "+lit.Value+" in a run of spaces")
				}
			default:
				if index, ok := chromeWidthArgument(node); ok {
					if lit := spacingLiteral(node.Args[index]); lit != nil {
						report(node, "spacing literal "+lit.Value+" in a width budget")
					}
				}
			}
		case *ast.BasicLit:
			if node.Kind == token.STRING && !tags[node] {
				if value, err := strconv.Unquote(node.Value); err == nil && strings.Contains(value, "  ") {
					report(node, "hand-typed run of spaces")
				}
			}
		}
		return true
	})
	return violations, nil
}

// isChromeStyleCall matches a method call such as style.Padding(...), but not a package function such as lipgloss.Width(text), which measures rather than sets.
func isChromeStyleCall(call *ast.CallExpr) bool {
	selector, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || !chromeStyleMethods[selector.Sel.Name] {
		return false
	}
	if pkg, ok := selector.X.(*ast.Ident); ok && isPackageName(pkg.Name) {
		return false
	}
	return true
}

func isPackageName(name string) bool {
	switch name {
	case "lipgloss", "ansi", "runewidth", "uniseg":
		return true
	}
	return false
}

// chromeWidthFunctions are the fitting and placement calls whose width argument is a chrome budget, keyed by package (empty for this package) and name, with the index of that argument.
var chromeWidthFunctions = map[[2]string]int{
	{"", "fit"}:                     1,
	{"", "renderPadded"}:            2,
	{"", "firstCompactLine"}:        1,
	{"ansi", "Truncate"}:            1,
	{"ansi", "TruncateWc"}:          1,
	{"ansi", "Wrap"}:                1,
	{"lipgloss", "PlaceHorizontal"}: 0,
}

// chromeWidthArgument returns the index of the width argument when call is one of chromeWidthFunctions.
func chromeWidthArgument(call *ast.CallExpr) (int, bool) {
	var key [2]string
	switch fun := call.Fun.(type) {
	case *ast.Ident:
		key = [2]string{"", fun.Name}
	case *ast.SelectorExpr:
		pkg, ok := fun.X.(*ast.Ident)
		if !ok {
			return 0, false
		}
		key = [2]string{pkg.Name, fun.Sel.Name}
	default:
		return 0, false
	}
	index, ok := chromeWidthFunctions[key]
	if !ok || index >= len(call.Args) {
		return 0, false
	}
	return index, true
}

// isSpaceRepeat matches strings.Repeat(" ", n), comparing the unquoted value so a raw-string space matches too.
func isSpaceRepeat(call *ast.CallExpr) bool {
	selector, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || selector.Sel.Name != "Repeat" || len(call.Args) != 2 {
		return false
	}
	if pkg, ok := selector.X.(*ast.Ident); !ok || pkg.Name != "strings" {
		return false
	}
	lit, ok := call.Args[0].(*ast.BasicLit)
	if !ok || lit.Kind != token.STRING {
		return false
	}
	value, err := strconv.Unquote(lit.Value)
	return err == nil && value != "" && strings.Trim(value, " ") == ""
}

// spacingLiteral returns the first non-zero integer literal in expr that is a spacing amount rather than layout arithmetic.
//
// Layout arithmetic passes: a literal that is a direct argument of a min or max clamp, an operand of * or /, or an index. Everything else, including an offset added to or subtracted from a measured value and a literal inside any other nested call, is spacing.
func spacingLiteral(expr ast.Expr) *ast.BasicLit {
	var found *ast.BasicLit
	var visit func(node ast.Node, exempt bool)
	visit = func(node ast.Node, exempt bool) {
		if found != nil || node == nil {
			return
		}
		switch node := node.(type) {
		case *ast.BasicLit:
			if !exempt && (node.Kind == token.INT || node.Kind == token.FLOAT) && !isZeroLiteral(node.Value) {
				found = node
			}
		case *ast.CallExpr:
			clamp := false
			if ident, ok := node.Fun.(*ast.Ident); ok && (ident.Name == "min" || ident.Name == "max") {
				clamp = true
			}
			visit(node.Fun, false)
			for _, arg := range node.Args {
				visit(arg, clamp)
			}
		case *ast.BinaryExpr:
			ratio := node.Op == token.MUL || node.Op == token.QUO
			visit(node.X, ratio)
			visit(node.Y, ratio)
		case *ast.IndexExpr:
			visit(node.X, false)
			visit(node.Index, true)
		case *ast.SliceExpr:
			visit(node.X, false)
			visit(node.Low, true)
			visit(node.High, true)
			visit(node.Max, true)
		case *ast.ParenExpr:
			visit(node.X, exempt)
		case *ast.FuncLit:
			// A closure argument is its own code; its body is checked where it calls a measurement.
		default:
			ast.Inspect(node, func(child ast.Node) bool {
				if child == node {
					return true
				}
				if child != nil {
					visit(child, false)
				}
				return false
			})
		}
	}
	visit(expr, false)
	return found
}

func isZeroLiteral(value string) bool {
	if number, err := strconv.ParseInt(value, 0, 64); err == nil {
		return number == 0
	}
	number, err := strconv.ParseFloat(strings.ReplaceAll(value, "_", ""), 64)
	return err == nil && number == 0
}

func TestChromeTokenGuardrailRejectsSpacingLiterals(t *testing.T) {
	fixtures := []string{
		`style.Padding(0, 1)`,
		`style.PaddingLeft(2)`,
		`style.Margin(1)`,
		`style.MarginTop(1)`,
		`style.Width(5)`,
		`style.Height(3)`,
		`style.MaxWidth(2)`,
		`style.MaxHeight(10)`,
		`style.Width(width - 3)`,
		`style.Width(margin - 1)`,
		`style.Width(max(width-1, 1))`,
		`style.Width(width + 2)`,
		`style.Width(-2)`,
		`style.Width(clamp(width, 4))`,
		`style.Width(int(3))`,
		`style.Width(flag * (width + 1))`,
		`style.Padding(0.5)`,
		`style.Width(0x10)`,
		`style.Width(0xB0)`,
		`style.Width(0b10)`,
		`style.Width(0o10)`,
		`style.Width(1_000)`,
		`style.Width(0 + 5)`,
		`strings.Repeat(" ", 2)`,
		`strings.Repeat(" ", indent+2)`,
		`strings.Repeat(" ", width-lipgloss.Width(left)-1)`,
		`strings.Repeat(" ", max(width-2, 0))`,
		"strings.Repeat(` `, 2)",
		`strings.Repeat("\x20", width-1)`,
		`fit(text, width-2)`,
		`fit(text, 12)`,
		`fit(text, max(width-lipgloss.Width(label)-9, 8))`,
		`renderPadded(style, text, width-2)`,
		`firstCompactLine(text, max(width-6, 8))`,
		`ansi.Truncate(text, width-3, "…")`,
		`ansi.TruncateWc(group, max(width-3, 1), "…")`,
		`ansi.Wrap(text, width-3, "")`,
		`lipgloss.PlaceHorizontal(width-2, lipgloss.Left, text)`,
		`"  "`,
		`"label  value"`,
		"`a  b`",
		`fmt.Sprintf("%s  %s", a, b)`,
	}
	for _, fixture := range fixtures {
		violations, err := chromeLiteralViolations("fixture.go", fixtureSource(fixture))
		if err != nil {
			t.Fatalf("%s: %v", fixture, err)
		}
		if len(violations) == 0 {
			t.Errorf("guard accepted a spacing literal: %s", fixture)
		}
	}
}

func TestChromeTokenGuardrailAcceptsLayoutArithmetic(t *testing.T) {
	fixtures := []string{
		`style.Padding(0)`,
		`style.Padding(0, 0)`,
		`style.Padding(0x0, 0.0)`,
		`style.Padding(padding(spaceHairline, spaceSM))`,
		`style.Width(max(width, 1))`,
		`style.Width(min(width, 64))`,
		`style.Width(available / 2)`,
		`style.Width(width * 3 / 4)`,
		`style.Width(width - spaceXL.cols())`,
		`style.Width(width - lipgloss.Width(left))`,
		`style.Width(rows[1])`,
		`style.Width(cols[1:3][0])`,
		`lipgloss.Width(rows[1] + "x")`,
		`lipgloss.Width(label) + 2`,
		`strings.Repeat(" ", width-lipgloss.Width(left))`,
		`strings.Repeat(" ", max(gapWidth, 1))`,
		`strings.Repeat(" ", available/2)`,
		`strings.Repeat(" ", spaceMD.cols())`,
		`strings.Repeat("─", width-2)`,
		`strings.Repeat("ab", 2)`,
		`fit(text, max(width, 1))`,
		`fit(text, width/2)`,
		`fit(text, width-lipgloss.Width(label))`,
		`renderPadded(style, text, width)`,
		`firstCompactLine(text, max(width-spaceXL.cols(), 8))`,
		`ansi.Truncate(text, width-lipgloss.Width(tail), "…")`,
		`ansi.TruncateWc(text, min(width, 40), "…")`,
		`ansi.Wrap(text, width*3/4, "")`,
		`lipgloss.PlaceHorizontal(width, lipgloss.Center, text)`,
		`m.fit(text, 2)`,
		`gap(spaceXL)`,
		`" "`,
		`"a b c"`,
		"`a b`",
	}
	for _, fixture := range fixtures {
		violations, err := chromeLiteralViolations("fixture.go", fixtureSource(fixture))
		if err != nil {
			t.Fatalf("%s: %v", fixture, err)
		}
		if len(violations) > 0 {
			t.Errorf("guard rejected layout arithmetic %s: %v", fixture, violations)
		}
	}
}

func TestChromeTokenGuardrailIgnoresStructTags(t *testing.T) {
	source := []byte("package fixture\n\ntype row struct {\n\tName string `json:\"name\"  yaml:\"name\"`\n}\n")
	violations, err := chromeLiteralViolations("fixture.go", source)
	if err != nil {
		t.Fatal(err)
	}
	if len(violations) > 0 {
		t.Errorf("struct tags are not chrome: %v", violations)
	}
}

func TestChromeTokenGuardrailRatchetRejectsStaleAndUnexplainedEntries(t *testing.T) {
	found := map[string][]string{"a.go": {"1: hand-typed run of spaces: \"  \""}}
	allowlist := []struct{ path, reason string }{{"a.go", " "}, {"a.go", "duplicate"}, {"gone.go", "stale"}}
	failures := strings.Join(chromeTokenRatchetFailures(found, allowlist), "\n")
	for _, want := range []string{"a.go: allowlist reason is empty", "a.go: duplicate allowlist entry", "gone.go: stale allowlist entry"} {
		if !strings.Contains(failures, want) {
			t.Errorf("ratchet failures missing %q in:\n%s", want, failures)
		}
	}
	if failures := chromeTokenRatchetFailures(found, nil); len(failures) != 1 || !strings.HasPrefix(failures[0], "a.go:1:") {
		t.Errorf("an unlisted violation must fail with its file and line, got %v", failures)
	}
}

func fixtureSource(expr string) []byte {
	return []byte("package fixture\n\nfunc fixture() {\n\t_ = " + expr + "\n}\n")
}
