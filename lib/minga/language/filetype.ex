defmodule Minga.Language.Filetype do
  @moduledoc """
  Detects a file's language from its path and content.

  Detection priority follows Neovim-style behavior, using `Minga.Language.Registry` as the single authority for both runtime overrides and language-pack entries:

  1. Runtime exact filename overrides
  2. Language-pack exact filename entries
  3. Runtime extension overrides
  4. Language-pack extension entries
  5. `.env*` / `.envrc*` pattern when `:bash` is still registered
  6. Shebang line from the first line of content (runtime override, then language-pack)
  7. Fall back to `:text`

  All lookups go through `Minga.Language.Registry` ETS reads. Runtime overrides live in a separate key namespace (`{:override_ext, _}`, `{:override_filename, _}`, `{:override_shebang, _}`) and are checked before language-pack entries.

  Each detection function also takes a registry table as its last argument, so tests can run the full precedence matrix against a private registry. Production callers use the short form, which reads the application registry.
  """

  alias Minga.Language.Registry, as: LangRegistry

  @typedoc "A language identifier atom."
  @type filetype :: atom()

  @typep table :: LangRegistry.table()

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Detects the language of a file from its path alone.

  Checks runtime filename overrides, bundled exact filenames, runtime extension overrides, bundled extensions, and `.env*`/`.envrc*` patterns in that order. Returns `:text` if nothing matches.
  """
  @spec detect(String.t() | nil, table()) :: filetype()
  def detect(file_path, table \\ LangRegistry.default_table())

  def detect(nil, _table), do: :text

  def detect(file_path, table) when is_binary(file_path) and is_atom(table) do
    file_path
    |> Path.basename()
    |> detect_basename(table)
  end

  @doc """
  Detects the languages of many paths, in input order, with the same priority as `detect/1`.

  Reads the runtime overrides from `Minga.Language.Registry` once for the whole list instead of once per path, so a caller that labels thousands of paths for one frame does not make thousands of ETS select calls.
  """
  @spec detect_all([String.t() | nil], table()) :: [filetype()]
  def detect_all(paths, table \\ LangRegistry.default_table())
      when is_list(paths) and is_atom(table) do
    %{filenames: filenames, extensions: extensions} = LangRegistry.override_path_entries(table)

    filename_override = &Map.get(filenames, &1, :miss)
    extension_override = &lookup_extension_in(extensions, &1)

    Enum.map(paths, fn
      nil ->
        :text

      path ->
        path
        |> Path.basename()
        |> detect_basename_with(filename_override, extension_override, table)
    end)
  end

  @doc """
  Detects the language from a file path and the first line of content.

  Tries `detect/1` first. If that returns `:text`, attempts shebang detection from `first_line`. Returns `:text` if nothing matches.
  """
  @spec detect_from_content(String.t() | nil, String.t() | nil, table()) :: filetype()
  def detect_from_content(file_path, first_line, table \\ LangRegistry.default_table())
      when is_atom(table) do
    case detect(file_path, table) do
      :text -> parse_shebang(first_line, table)
      filetype -> filetype
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec detect_basename(String.t(), table()) :: filetype()
  defp detect_basename(basename, table) do
    with :miss <- lookup_override_filename(basename, table),
         :miss <- lookup_lang_registry_filename(basename, table),
         :miss <- lookup_override_extension(basename, table),
         :miss <- lookup_lang_registry_extension(basename, table),
         :miss <- detect_env_pattern(basename, table) do
      :text
    end
  end

  @spec detect_basename_with(
          String.t(),
          (String.t() -> filetype() | :miss),
          (String.t() -> filetype() | :miss),
          table()
        ) :: filetype()
  defp detect_basename_with(basename, filename_override, extension_override, table) do
    with :miss <- filename_override.(basename),
         :miss <- lookup_lang_registry_filename(basename, table),
         :miss <- extension_override.(basename),
         :miss <- lookup_lang_registry_extension(basename, table),
         :miss <- detect_env_pattern(basename, table) do
      :text
    end
  end

  @spec lookup_extension_in(%{String.t() => filetype()}, String.t()) :: filetype() | :miss
  defp lookup_extension_in(extensions, basename) do
    case Path.extname(basename) do
      "" -> :miss
      "." <> ext -> Map.get(extensions, String.downcase(ext), :miss)
    end
  end

  @spec lookup_override_filename(String.t(), table()) :: filetype() | :miss
  defp lookup_override_filename(basename, table) do
    case LangRegistry.lookup_override_filename(basename, table) do
      nil -> :miss
      filetype -> filetype
    end
  end

  @spec lookup_override_extension(String.t(), table()) :: filetype() | :miss
  defp lookup_override_extension(basename, table) do
    case Path.extname(basename) do
      "" ->
        :miss

      "." <> ext ->
        case LangRegistry.lookup_override_extension(String.downcase(ext), table) do
          nil -> :miss
          filetype -> filetype
        end
    end
  end

  @spec lookup_lang_registry_filename(String.t(), table()) :: filetype() | :miss
  defp lookup_lang_registry_filename(basename, table) do
    case LangRegistry.for_filename(basename, table) do
      %{name: name} -> name
      nil -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @spec lookup_lang_registry_extension(String.t(), table()) :: filetype() | :miss
  defp lookup_lang_registry_extension(basename, table) do
    case Path.extname(basename) do
      "" ->
        :miss

      "." <> ext ->
        case LangRegistry.for_extension(String.downcase(ext), table) do
          %{name: name} -> name
          nil -> :miss
        end
    end
  rescue
    ArgumentError -> :miss
  end

  @spec detect_env_pattern(String.t(), table()) :: filetype() | :miss
  defp detect_env_pattern(".env" <> _rest, table), do: lookup_lang_registry_bash(table)
  defp detect_env_pattern(_basename, _table), do: :miss

  @spec lookup_lang_registry_bash(table()) :: filetype() | :miss
  defp lookup_lang_registry_bash(table) do
    case LangRegistry.get(:bash, table) do
      %{name: :bash} -> :bash
      nil -> :miss
    end
  end

  @spec parse_shebang(String.t() | nil, table()) :: filetype()
  defp parse_shebang(nil, _table), do: :text
  defp parse_shebang("", _table), do: :text

  defp parse_shebang("#!" <> rest, table) do
    interpreter =
      rest
      |> String.trim()
      |> extract_interpreter()

    case LangRegistry.lookup_override_shebang(interpreter, table) do
      nil -> lookup_lang_registry_shebang(interpreter, table)
      filetype -> filetype
    end
  end

  defp parse_shebang(_line, _table), do: :text

  @spec lookup_lang_registry_shebang(String.t(), table()) :: filetype()
  defp lookup_lang_registry_shebang(interpreter, table) do
    case LangRegistry.for_shebang(interpreter, table) do
      %{name: name} -> name
      nil -> :text
    end
  end

  @spec extract_interpreter(String.t()) :: String.t()
  defp extract_interpreter(shebang_path) do
    case String.split(shebang_path) do
      [_env_path, interpreter | _] -> Path.basename(interpreter)
      [path | _] -> Path.basename(path)
      [] -> ""
    end
  end
end
