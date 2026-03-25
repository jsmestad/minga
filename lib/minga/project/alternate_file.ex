defmodule Minga.Project.AlternateFile do
  @moduledoc """
  Finds the "alternate" file for a given source file.

  Alternate files are the natural counterpart to the file you're editing:
  test ↔ implementation for most languages, header ↔ source for C/C++.
  The mapping is bidirectional and based on path conventions.

  Supported languages and their patterns:

  | Language   | Source              | Alternate                  |
  |------------|---------------------|----------------------------|
  | Elixir     | `lib/**/*.ex`       | `test/**/*_test.exs`       |
  | Ruby       | `app/**/*.rb`       | `spec/**/*_spec.rb`        |
  | Ruby       | `lib/**/*.rb`       | `spec/**/*_spec.rb`        |
  | TypeScript | `src/**/*.ts(x)`    | `src/**/*.test.ts(x)`      |
  | TypeScript | `src/**/*.ts(x)`    | `src/**/*.spec.ts(x)`      |
  | C/C++      | `*.c` / `*.cpp`     | `*.h` / `*.hpp`            |
  | Swift      | `Sources/**/*.swift`| `Tests/**/*Tests.swift`    |

  When multiple candidates exist, the first one that exists on disk wins.
  If none exist, the first convention is returned as the default.
  """

  @doc """
  Returns candidate alternate file paths for the given file.

  This is a pure calculation with no I/O. The caller is responsible
  for checking which candidates exist on disk and choosing one.

  The `project_root` anchors the returned absolute paths. Candidates
  are returned in priority order (first is the preferred convention).

  Returns an empty list if no alternate pattern matches.

  ## Examples

      iex> Minga.Project.AlternateFile.candidates("/project/lib/foo.ex", :elixir, "/project")
      ["/project/test/foo_test.exs"]

      iex> Minga.Project.AlternateFile.candidates("/project/test/foo_test.exs", :elixir, "/project")
      ["/project/lib/foo.ex"]

      iex> Minga.Project.AlternateFile.candidates("/project/notes.txt", :text, "/project")
      []
  """
  @spec candidates(String.t(), atom(), String.t()) :: [String.t()]
  def candidates(file_path, filetype, project_root)
      when is_binary(file_path) and is_atom(filetype) and is_binary(project_root) do
    rel = Path.relative_to(file_path, project_root)

    rel
    |> candidates_for(filetype)
    |> Enum.map(fn p -> Path.join(project_root, p) end)
  end

  # ── Elixir ─────────────────────────────────────────────────────────────────

  @spec candidates_for(String.t(), atom()) :: [String.t()]

  # lib/foo/bar.ex → test/foo/bar_test.exs
  defp candidates_for("lib/" <> rest, :elixir) do
    base = Path.rootname(rest, ".ex")
    ["test/#{base}_test.exs"]
  end

  # test/foo/bar_test.exs → lib/foo/bar.ex
  defp candidates_for("test/" <> rest, :elixir) do
    base = Path.rootname(rest, ".exs")
    trimmed = String.replace_suffix(base, "_test", "")

    if trimmed != base do
      ["lib/#{trimmed}.ex"]
    else
      []
    end
  end

  # ── Ruby ───────────────────────────────────────────────────────────────────

  # app/models/foo.rb → spec/models/foo_spec.rb
  defp candidates_for("app/" <> rest, :ruby) do
    base = Path.rootname(rest, ".rb")
    ["spec/#{base}_spec.rb"]
  end

  # lib/foo.rb → spec/lib/foo_spec.rb, spec/foo_spec.rb
  defp candidates_for("lib/" <> rest, :ruby) do
    base = Path.rootname(rest, ".rb")
    ["spec/lib/#{base}_spec.rb", "spec/#{base}_spec.rb"]
  end

  # spec/models/foo_spec.rb → app/models/foo.rb
  # spec/lib/foo_spec.rb → lib/foo.rb
  # spec/foo_spec.rb → lib/foo.rb, app/foo.rb
  defp candidates_for("spec/" <> rest, :ruby) do
    base = Path.rootname(rest, ".rb")
    trimmed = String.replace_suffix(base, "_spec", "")

    if trimmed != base do
      case trimmed do
        "lib/" <> lib_rest -> ["lib/#{lib_rest}.rb"]
        _ -> ["app/#{trimmed}.rb", "lib/#{trimmed}.rb"]
      end
    else
      []
    end
  end

  # ── TypeScript / JavaScript ────────────────────────────────────────────────

  # Handle .ts, .tsx, .js, .jsx — dispatch to multi-clause helper
  defp candidates_for(path, filetype)
       when filetype in [:typescript, :typescript_react, :javascript, :javascript_react] do
    ext = Path.extname(path)
    base = Path.rootname(path)
    ts_candidates(base, ext, path)
  end

  # ── C / C++ (header ↔ source) ──────────────────────────────────────────────

  defp candidates_for(path, :c) do
    ext = Path.extname(path)
    base = Path.rootname(path)

    case ext do
      ".c" -> ["#{base}.h"]
      ".h" -> ["#{base}.c"]
      _ -> []
    end
  end

  defp candidates_for(path, :cpp) do
    ext = Path.extname(path)
    base = Path.rootname(path)

    case ext do
      ".cpp" -> ["#{base}.hpp", "#{base}.h"]
      ".cc" -> ["#{base}.hpp", "#{base}.h"]
      ".cxx" -> ["#{base}.hpp", "#{base}.h"]
      ".hpp" -> ["#{base}.cpp", "#{base}.cc", "#{base}.cxx"]
      ".h" -> ["#{base}.cpp", "#{base}.cc", "#{base}.cxx"]
      _ -> []
    end
  end

  # ── Swift ──────────────────────────────────────────────────────────────────

  # Sources/Foo/Bar.swift → Tests/Foo/BarTests.swift
  defp candidates_for("Sources/" <> rest, :swift) do
    base = Path.rootname(rest, ".swift")
    ["Tests/#{base}Tests.swift"]
  end

  # Tests/Foo/BarTests.swift → Sources/Foo/Bar.swift
  defp candidates_for("Tests/" <> rest, :swift) do
    base = Path.rootname(rest, ".swift")
    trimmed = String.replace_suffix(base, "Tests", "")

    if trimmed != base do
      ["Sources/#{trimmed}.swift"]
    else
      []
    end
  end

  # ── Fallback ───────────────────────────────────────────────────────────────

  defp candidates_for(_path, _filetype), do: []

  # ── TypeScript / JavaScript helpers ────────────────────────────────────────

  # __tests__/foo.test.ts → src/foo.ts
  @spec ts_candidates(String.t(), String.t(), String.t()) :: [String.t()]
  defp ts_candidates("__tests__/" <> rest, ext, _path) do
    source = String.replace_suffix(rest, ".test", "")
    ["src/#{source}#{ext}"]
  end

  # foo.test.ts → foo.ts, foo.spec.ts → foo.ts, foo.ts → [foo.test.ts, foo.spec.ts]
  defp ts_candidates(base, ext, _path) when is_binary(base) do
    case {String.ends_with?(base, ".test"), String.ends_with?(base, ".spec")} do
      {true, _} ->
        source = String.replace_suffix(base, ".test", "")
        ["#{source}#{ext}"]

      {_, true} ->
        source = String.replace_suffix(base, ".spec", "")
        ["#{source}#{ext}"]

      {false, false} ->
        ts_source_candidates(base, ext)
    end
  end

  # foo.ts → foo.test.ts, foo.spec.ts, __tests__/foo.test.ts
  @spec ts_source_candidates(String.t(), String.t()) :: [String.t()]
  defp ts_source_candidates(base, ext) do
    dir = Path.dirname(base)
    dir_prefix = if dir == ".", do: "", else: dir <> "/"
    name = Path.basename(base)

    test_candidates = [
      "#{dir_prefix}#{name}.test#{ext}",
      "#{dir_prefix}#{name}.spec#{ext}"
    ]

    if String.starts_with?(base, "src/") do
      rel = String.replace_prefix(base, "src/", "")
      test_candidates ++ ["__tests__/#{rel}.test#{ext}"]
    else
      test_candidates
    end
  end
end
