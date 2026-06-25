defmodule MingaEditor.UI.Theme.CaptureCoverageTest do
  @moduledoc """
  Regression guard against "invisible" tree-sitter captures.

  Faces resolve through `MingaEditor.UI.Face.Registry`, which walks the dotted
  capture name (`Minga.Core.Face.infer_parent/1`) up to a styled ancestor or,
  failing that, to the editor's default foreground. A capture that resolves to
  the editor default fg with no distinguishing attribute is effectively
  invisible: it renders identically to plain body text.

  This test enumerates every distinct `@capture` used across
  `priv/queries/**/highlights.scm` and asserts each resolves to a *styled*
  face (a foreground different from the editor default, or a bold / italic /
  underline / strikethrough attribute). A small, explicitly documented
  allowlist covers captures that a theme deliberately renders as plain text.

  Two themes are checked:

    * `:astrodark` - a real built-in theme whose palette intentionally mutes
      operators, variables, members, parameters, etc. to the editor foreground
      (it mirrors AstroNvim's astrotheme, where those captures are plain).
    * a synthetic builder-default theme built from a palette where every role
      is a distinct color. Here nothing is muted, so the only plain captures
      are the universal sentinels (`markup` body prose, `none`, `spell`). This
      proves `MingaEditor.UI.Theme.Builder`'s face map covers every capture.

  The test also asserts the LSP semantic-token captures emitted by
  `Minga.LSP.SemanticTokens` (`@lsp.type.*` / `@lsp.mod.*`) resolve to styled
  faces, since nothing styled them before this guard was added.
  """

  use ExUnit.Case, async: true

  alias Minga.Core.Face
  alias MingaEditor.UI.Face.Registry
  alias MingaEditor.UI.Theme
  alias MingaEditor.UI.Theme.Builder

  # Captures a theme is allowed to render as plain editor-foreground text.
  #
  # `none` and `spell` are non-styling sentinel captures (tree-sitter uses them
  # to clear or annotate, not to color). `markup` is base prose body text,
  # which renders at the editor foreground by design.
  @universal_plain MapSet.new(~w(none spell markup))

  # AstroDark deliberately maps these to the editor foreground (`@syn_text`)
  # via `operators`/`variables` palette roles and explicit syntax overrides,
  # matching AstroNvim's astrotheme. They are intentionally plain, not bugs.
  @astrodark_plain MapSet.union(
                     @universal_plain,
                     MapSet.new(~w(
                       operator
                       variable
                       variable.array
                       variable.hash
                       variable.member
                       variable.parameter
                       variable.parameter.builtin
                       variable.scalar
                       parameter
                       field
                       property
                       property.definition
                       embedded
                       escape
                       string.escape
                       punctuation.special
                     ))
                   )

  # LSP semantic-token captures emitted by Minga.LSP.SemanticTokens.
  @lsp_captures ~w(
    @lsp.type.namespace @lsp.type.type @lsp.type.variable @lsp.type.parameter
    @lsp.type.property @lsp.type.function @lsp.type.method @lsp.type.keyword
    @lsp.type.comment @lsp.type.string @lsp.type.number @lsp.type.operator
    @lsp.mod.deprecated @lsp.mod.readonly
  )

  describe "every query capture resolves to a visible face" do
    test "the enumerator finds the full distinct capture set" do
      # The captured set is computed from a per-line parse, so an unbalanced
      # `"` inside a comment can't pair across newlines and swallow captures.
      # Lock the count so a future parse regression that silently drops a
      # capture (and lets it escape the coverage guard) fails loudly here.
      assert Enum.count(all_query_captures()) == 113
    end

    test "astrodark styles all captures except its documented plain set" do
      reg = Registry.from_theme(Theme.get!(:astrodark))
      default_fg = Theme.get!(:astrodark).editor.fg

      invisible =
        Enum.reject(all_query_captures(), fn capture ->
          MapSet.member?(@astrodark_plain, capture) or
            styled?(Registry.style_for(reg, capture), default_fg)
        end)

      assert invisible == [],
             "captures resolve to the editor default fg in :astrodark " <>
               "(invisible). Either add a face in the theme/Builder or add " <>
               "them to @astrodark_plain with a rationale: #{inspect(invisible)}"
    end

    test "a builder-default theme styles every capture except the sentinels" do
      reg = Registry.from_theme(distinct_palette_theme())
      default_fg = distinct_palette_theme().editor.fg

      invisible =
        Enum.reject(all_query_captures(), fn capture ->
          MapSet.member?(@universal_plain, capture) or
            styled?(Registry.style_for(reg, capture), default_fg)
        end)

      assert invisible == [],
             "the Builder face map leaves these captures invisible in a " <>
               "distinct-color theme: #{inspect(invisible)}"
    end
  end

  # Expected astrodark foregrounds per the Builder's LSP mapping: each
  # `@lsp.type.*` shares the SAME palette role color as the equivalent
  # tree-sitter capture. `variable`/`parameter`/`operator` resolve to the
  # editor foreground because astrodark deliberately mutes those roles.
  @astrodark_lsp_fg %{
    # variables/operators map to @syn_text (the editor fg) in astrodark.
    "@lsp.type.variable" => 0xADB0BB,
    "@lsp.type.parameter" => 0xADB0BB,
    "@lsp.type.operator" => 0xADB0BB,
    "@lsp.type.namespace" => 0xDFAB25,
    "@lsp.type.type" => 0xDFAB25,
    "@lsp.type.property" => 0x4AC2B8,
    "@lsp.type.function" => 0x5EB7FF,
    "@lsp.type.method" => 0x5EB7FF,
    "@lsp.type.keyword" => 0xDD97F1,
    "@lsp.type.comment" => 0x696C76,
    "@lsp.type.string" => 0x87C05F,
    "@lsp.type.number" => 0xF5983A
  }

  describe "LSP semantic-token captures resolve to styled faces" do
    test "astrodark: every LSP face is defined with the mapped color" do
      reg = Registry.from_theme(Theme.get!(:astrodark))

      # All LSP captures must be defined faces, not undefined fallbacks. An
      # undefined `@lsp.*` capture resolves to the module default (wrong bg),
      # which is exactly the bug this guards against.
      for capture <- @lsp_captures do
        assert Registry.get(reg, capture) != nil,
               "#{capture} is not a defined face; it would fall through to the " <>
                 "module default with the wrong background"
      end

      for {lsp, expected_fg} <- @astrodark_lsp_fg do
        assert Registry.style_for(reg, lsp).fg == expected_fg,
               "#{lsp} should resolve to 0x#{Integer.to_string(expected_fg, 16)}"
      end

      # The deprecated modifier composes strikethrough regardless of color.
      assert Registry.style_for(reg, "@lsp.mod.deprecated").strikethrough == true
      # readonly maps to the constant color (a visible accent).
      assert styled?(Registry.style_for(reg, "@lsp.mod.readonly"), 0xADB0BB)
    end

    test "builder-default theme: every LSP face is styled" do
      theme = distinct_palette_theme()
      reg = Registry.from_theme(theme)

      for capture <- @lsp_captures do
        face = Registry.style_for(reg, capture)

        assert styled?(face, theme.editor.fg),
               "#{capture} resolves to a plain default face in the builder " <>
                 "default theme"
      end
    end
  end

  # A face is "styled" if it visibly differs from plain body text: a different
  # foreground, or any distinguishing attribute (a modifier face like
  # @lsp.mod.deprecated carries strikethrough without changing the fg).
  defp styled?(%Face{} = face, default_fg) do
    face.fg != default_fg or face.bold == true or face.italic == true or
      face.underline == true or face.strikethrough == true
  end

  # Build a theme from a palette where every role is a distinct color, none
  # equal to the editor foreground. Used to prove Builder coverage independent
  # of any one theme's deliberate mutes.
  defp distinct_palette_theme do
    palette = %{
      variant: :dark,
      bg: 0x000000,
      fg: 0xFFFFFF,
      surface: 0x101010,
      overlay: 0x202020,
      muted: 0x303030,
      subtle: 0x404040,
      accent: 0x111111,
      highlight: 0x112233,
      selection_bg: 0x223344,
      error: 0xFF0001,
      warning: 0xFF8800,
      info: 0x0088FF,
      success: 0x00FF01,
      match: 0xFFFF00,
      link: 0x00FFFF,
      border: 0x445566,
      contrast_fg: 0x010101,
      builtin: 0x11AA11,
      functions: 0x2266FF,
      keywords: 0xAA22FF,
      methods: 0x33AAFF,
      operators: 0xFF66AA,
      constants: 0xFFAA22,
      strings: 0x66CC33,
      numbers: 0xCC8822,
      type: 0xDDAA22,
      variables: 0xCCCCEE,
      comments: 0x778899
    }

    Builder.from_palette(:capture_coverage_probe, palette)
  end

  # Distinct `@capture` names used across every built-in highlights query,
  # excluding comment lines (`; ...`) and quoted literals (e.g. objc's
  # `"@optional"` token strings, which are not capture annotations).
  defp all_query_captures do
    query_files()
    |> Enum.flat_map(&captures_in_file/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp query_files do
    [Application.app_dir(:minga, "priv"), "queries", "*", "highlights.scm"]
    |> Path.join()
    |> Path.wildcard()
  end

  defp captures_in_file(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.map_join("\n", &strip_line/1)
    |> then(&Regex.scan(~r/@[A-Za-z][A-Za-z0-9_.]*/, &1))
    |> Enum.map(fn [match] -> String.trim_leading(match, "@") end)
  end

  # Parse a single line: strip strings, then comments. Both run per line so an
  # unbalanced `"` inside a `;` comment can't pair across newlines and swallow
  # the text between them, which would let a unique capture escape the guard.
  #
  # Strings before comments: a literal string token like `";"` contains a `;`,
  # so stripping comments first would truncate the line mid-string and drop a
  # real capture that follows on the same line.
  defp strip_line(line) do
    line
    |> strip_strings()
    |> strip_comments()
  end

  defp strip_comments(line) do
    Regex.replace(~r/;.*$/, line, "")
  end

  # Remove double-quoted string literals, honoring backslash escapes so a
  # literal like `"\\"` (a single escaped backslash) is consumed as one string
  # rather than desyncing the quote pairing for the rest of the line.
  defp strip_strings(line) do
    Regex.replace(~r/"(?:[^"\\]|\\.)*"/, line, "")
  end
end
