defmodule Minga.RenderModel.FrontendTokenGuardrailsTest do
  @moduledoc """
  Frontends draw colours, state words and voice lines from the design tokens (`docs/design_tokens.toml`), never from literals in view or render code.

  Colour literals that existed when this guard landed are listed in `test/fixtures/design/colour_literal_baseline.tsv`. The baseline only shrinks: remove a row when its literal goes away, and never add one.
  """

  use ExUnit.Case, async: true

  alias Minga.Design.Tokens

  @repo_root Path.expand("../../..", __DIR__)
  @baseline_path "test/fixtures/design/colour_literal_baseline.tsv"

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

  @swift_colour_literal ~r/Color\(red:|NSColor\((?:calibrated|srgb|device)?[rR]ed:|Color\(hex|0x[0-9A-Fa-f]{6}\b|Color\.(?:red|green|blue|orange|yellow|purple|pink|mint|teal|cyan|indigo|brown)\b|\(\.(?:red|green|blue|orange|yellow|purple|pink|mint|teal|cyan|indigo|brown)\)/
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

  test "state words and voice lines come from the design tokens, not view literals" do
    words = Enum.map(Tokens.state_ids(), &Tokens.state_word/1)
    voice = Enum.map([:welcome, :done, :farewell], &Tokens.voice/1)
    literals = Enum.map(words ++ voice, &~s("#{&1}"))

    violations =
      for {path, lines} <- frontend_sources(),
          {line, number} <- Enum.with_index(lines, 1),
          literal <- literals,
          String.contains?(line, literal) do
        "#{path}:#{number}: #{literal}"
      end

    assert violations == [], """
    Use the generated tokens (SpineState.word and Voice in Swift, generated.SpineState.Token().Word and generated.Voice* in Go) instead of string literals:

    #{Enum.join(violations, "\n")}
    """
  end

  test "the baseline only names files that exist" do
    for {path, _line} <- baseline_rows() do
      assert File.exists?(Path.join(@repo_root, path)),
             "#{@baseline_path} names missing file #{path}"
    end
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
