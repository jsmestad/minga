defmodule Minga.RenderModel.FrontendTokenGuardrailsTest do
  @moduledoc """
  Frontends draw colours, state words and voice lines from the design tokens (`docs/design_tokens.toml`), never from literals in view or render code.

  Colour literals that existed when this guard landed are listed in `test/fixtures/design/colour_literal_baseline.tsv`. The baseline only shrinks: remove a row when its literal goes away, and never add one.

  A string literal names a state or a voice line when, ignoring case, the whole literal or one of its labelled segments is a state word or voice line. Segments are split at `:`, `·`, `•` and `|`. Surrounding spaces, punctuation and glyphs are ignored, and so are Swift interpolations and Go format verbs. So `"done"`, `"● Done"`, `"Waiting · "` and `"Done: \\(todo)"` name a state, and `"Waiting for your answer"` or `"Working tree clean"` do not. Comment lines are not scanned.

  State words that existed when the stricter rule landed, and whose migration belongs to a later surface ticket, are listed with a reason in `test/fixtures/design/state_word_baseline.tsv`. That baseline only shrinks as well.
  """

  use ExUnit.Case, async: true

  alias Minga.Design.Tokens

  @repo_root Path.expand("../../..", __DIR__)
  @baseline_path "test/fixtures/design/colour_literal_baseline.tsv"
  @state_word_baseline_path "test/fixtures/design/state_word_baseline.tsv"

  # Theme definitions, generated token sources and preview fixtures that stand in for a theme may hold colours.
  @swift_exempt [
    ~r{^macos/Sources/Views/Shared/ThemeColors\.swift$},
    ~r{\.generated\.swift$},
    ~r{^macos/Sources/PreviewFixtures\.swift$},
    ~r{^macos/Sources/PreviewRegistry(\+[A-Za-z]+)?\.swift$}
  ]

  @go_exempt [
    ~r{_test\.go$},
    ~r{^go/tui/internal/generated/},
    ~r{^go/tui/internal/ui/theme\.go$}
  ]

  # Named colours match as `Color.red` or as a leading-dot member such as `.white` in `.foregroundStyle(.white)` or `return .gray`.
  # The lookbehind skips member access on another value (`theme.red`) and the `.black` font weight.
  @swift_colour_literal ~r/Color\((?:\.sRGB(?:Linear)?,\s*)?(?:red|white):|NSColor\((?:calibrated|srgb|device|generic)?(?:[rR]ed|[wW]hite):|Color\(hex|0x[0-9A-Fa-f]{6}\b|Color\.(?:red|green|blue|orange|yellow|purple|pink|mint|teal|cyan|indigo|brown|white|black|gray)\b|(?<![\w)\].]|weight: |Weight\()\.(?:red|green|blue|orange|yellow|purple|pink|mint|teal|cyan|indigo|brown|white|black|gray)\b/
  @go_colour_literal ~r/lipgloss\.Color\("|color\.RGBA\{/

  test "view and render code adds no colour literal outside theme and generated files" do
    current = colour_literal_rows()
    baseline = baseline_rows()

    added = current -- baseline
    stale = baseline -- current

    assert added == [], """
    Colour literals in view or render code. Draw a theme slot or a design token colour role instead (ThemeColors.roleColor(_:) in Swift, palette.Role in Go).

    #{format_rows(added)}
    """

    assert stale == [], """
    These baseline rows no longer match a literal. Delete them from #{@baseline_path}:

    #{format_rows(stale)}
    """
  end

  test "the Swift colour rule catches white, black, gray and leading-dot colours but not font weights" do
    literals = [
      ".foregroundStyle(.white)",
      ".shadow(color: .black.opacity(0.4), radius: 12)",
      "case .debug: return .gray",
      "badge(\"!\", color: .red)",
      "Color.gray",
      "Color(white: 0.5)",
      "Color(.sRGB, white: 0.2, opacity: 1)",
      "NSColor(white: 1, alpha: 1)",
      "NSColor(calibratedWhite: 0, alpha: 1)"
    ]

    others = [
      ".fontWeight(.black)",
      ".font(.system(size: 12, weight: .black))",
      "theme.red",
      "theme.roleColor(.needsYou)"
    ]

    for line <- literals,
        do:
          assert(Regex.match?(@swift_colour_literal, line), "#{line} should be a colour literal")

    for line <- others,
        do:
          refute(
            Regex.match?(@swift_colour_literal, line),
            "#{line} should not be a colour literal"
          )
  end

  test "state words and voice lines come from the design tokens, not view literals" do
    current = state_word_rows()
    baseline = Enum.map(state_word_baseline_rows(), fn {path, line, _reason} -> {path, line} end)

    added = current -- baseline
    stale = baseline -- current

    assert added == [], """
    Use the generated tokens (SpineState.word and Voice in Swift, generated.SpineState.Token().Word and generated.Voice* in Go) instead of string literals:

    #{format_rows(added)}
    """

    assert stale == [], """
    These baseline rows no longer name a state in a literal. Delete them from #{@state_word_baseline_path}:

    #{format_rows(stale)}
    """
  end

  test "the state word rule ignores case and labels but not sentences" do
    named = [
      "done",
      "Needs you",
      "● Done",
      "  working…  ",
      "Waiting · ",
      "Done: \\(todo.description)",
      "%s · failed",
      "servus"
    ]

    unnamed = [
      "Waiting for your answer",
      "Working tree clean",
      "Agent needs you",
      "Kept you waiting, huh?",
      "Done editing"
    ]

    for literal <- named,
        do: assert(names_state?(literal), "#{inspect(literal)} should name a state")

    for literal <- unnamed,
        do: refute(names_state?(literal), "#{inspect(literal)} should not name a state")
  end

  test "every state word baseline row gives a reason" do
    for {path, line, reason} <- state_word_baseline_rows() do
      assert String.trim(reason) != "",
             "#{@state_word_baseline_path} row #{path}: #{line} has no reason"
    end
  end

  test "the baselines only name files that exist" do
    for {path, _line} <- baseline_rows() do
      assert File.exists?(Path.join(@repo_root, path)),
             "#{@baseline_path} names missing file #{path}"
    end

    for {path, _line, _reason} <- state_word_baseline_rows() do
      assert File.exists?(Path.join(@repo_root, path)),
             "#{@state_word_baseline_path} names missing file #{path}"
    end
  end

  @string_literal ~r/"((?:[^"\\\n]|\\.)*)"/
  @placeholder ~r/\\\((?:[^()]|\([^()]*\))*\)|%[-+# 0-9.]*[a-zA-Z@]/
  @segment_separator ~r/[:·•|]/u
  @edge_noise ~r/^[^\p{L}]+|[^\p{L}]+$/u

  @spec state_word_rows() :: [{String.t(), String.t()}]
  defp state_word_rows do
    for {path, lines} <- frontend_sources(),
        line <- lines,
        not comment?(line),
        [_quoted, literal] <- Regex.scan(@string_literal, line),
        names_state?(literal) do
      {path, String.trim(line)}
    end
  end

  @spec comment?(String.t()) :: boolean()
  defp comment?(line), do: line |> String.trim_leading() |> String.starts_with?("//")

  @spec names_state?(String.t()) :: boolean()
  defp names_state?(literal) do
    targets = state_and_voice_words()

    @placeholder
    |> Regex.replace(literal, "")
    |> String.split(@segment_separator)
    |> Enum.any?(&(normalise(&1) in targets))
  end

  @spec state_and_voice_words() :: [String.t()]
  defp state_and_voice_words do
    words = Enum.map(Tokens.state_ids(), &Tokens.state_word/1)
    voice = Enum.map([:welcome, :done, :farewell], &Tokens.voice/1)
    Enum.map(words ++ voice, &normalise/1)
  end

  @spec normalise(String.t()) :: String.t()
  defp normalise(text) do
    @edge_noise
    |> Regex.replace(text, "")
    |> String.downcase()
    |> String.split()
    |> Enum.join(" ")
  end

  @spec state_word_baseline_rows() :: [{String.t(), String.t(), String.t()}]
  defp state_word_baseline_rows do
    @repo_root
    |> Path.join(@state_word_baseline_path)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(fn row ->
      [path, reason, line] = String.split(row, "\t", parts: 3)
      {path, line, reason}
    end)
  end

  @spec colour_literal_rows() :: [{String.t(), String.t()}]
  defp colour_literal_rows do
    for {path, lines} <- frontend_sources(),
        line <- lines,
        _match <- Regex.scan(colour_pattern(path), line) do
      {path, String.trim(line)}
    end
  end

  @spec frontend_sources() :: [{String.t(), [String.t()]}]
  defp frontend_sources do
    swift = sources("macos/Sources/**/*.swift", @swift_exempt)
    go = sources("go/tui/internal/**/*.go", @go_exempt)

    for path <- swift ++ go do
      {path, @repo_root |> Path.join(path) |> File.read!() |> String.split("\n")}
    end
  end

  @spec sources(String.t(), [Regex.t()]) :: [String.t()]
  defp sources(glob, exempt) do
    @repo_root
    |> Path.join(glob)
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, @repo_root))
    |> Enum.reject(fn path -> Enum.any?(exempt, &Regex.match?(&1, path)) end)
    |> Enum.sort()
  end

  @spec colour_pattern(String.t()) :: Regex.t()
  defp colour_pattern(path) do
    if String.ends_with?(path, ".go"), do: @go_colour_literal, else: @swift_colour_literal
  end

  @spec baseline_rows() :: [{String.t(), String.t()}]
  defp baseline_rows do
    @repo_root
    |> Path.join(@baseline_path)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(fn row ->
      [path, line] = String.split(row, "\t", parts: 2)
      {path, line}
    end)
  end

  @spec format_rows([{String.t(), String.t()}]) :: String.t()
  defp format_rows(rows), do: Enum.map_join(rows, "\n", fn {path, line} -> "#{path}\t#{line}" end)
end
