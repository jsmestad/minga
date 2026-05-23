defmodule Minga.Language.Filetype do
  @moduledoc """
  Detects a file's language from its path and content.

  Detection priority follows Neovim-style behavior:

  1. Runtime exact filename overrides from `Minga.Language.Filetype.Registry`
  2. Source-owned exact filename entries from `Minga.Language.Registry`
  3. Runtime extension overrides from `Minga.Language.Filetype.Registry`
  4. Source-owned extension entries from `Minga.Language.Registry`
  5. `.env*` / `.envrc*` pattern when `:bash` is still registered
  6. Shebang line from the first line of content
  7. Fall back to `:text`

  Built-in language mappings come from registered language definitions in `Minga.Language.Registry`. Runtime overrides stay separate so config and extensions can temporarily redirect a pattern without owning a full language definition.
  """

  alias Minga.Language.Registry, as: LangRegistry

  @typedoc "A language identifier atom."
  @type filetype :: atom()

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Detects the language of a file from its path alone.

  Checks runtime filename overrides, bundled exact filenames, runtime extension overrides, bundled extensions, and `.env*`/`.envrc*` patterns in that order. Returns `:text` if nothing matches.
  """
  @spec detect(String.t() | nil) :: filetype()
  def detect(nil), do: :text

  def detect(file_path) when is_binary(file_path) do
    basename = Path.basename(file_path)

    with :miss <- lookup_registry_filename(basename),
         :miss <- lookup_lang_registry_filename(basename),
         :miss <- lookup_registry_extension(basename),
         :miss <- lookup_lang_registry_extension(basename),
         :miss <- detect_env_pattern(basename) do
      :text
    end
  end

  @doc """
  Detects the language from a file path and the first line of content.

  Tries `detect/1` first. If that returns `:text`, attempts shebang detection from `first_line`. Returns `:text` if nothing matches.
  """
  @spec detect_from_content(String.t() | nil, String.t() | nil) :: filetype()
  def detect_from_content(file_path, first_line) do
    case detect(file_path) do
      :text -> parse_shebang(first_line)
      filetype -> filetype
    end
  end

  @doc "Returns runtime filename overrides. Registered language definitions live in `Minga.Language.Registry`, so this map is empty in normal builds."
  @spec filenames() :: %{String.t() => filetype()}
  def filenames, do: %{}

  @doc "Returns runtime extension overrides. Registered language definitions live in `Minga.Language.Registry`, so this map is empty in normal builds."
  @spec extensions() :: %{String.t() => filetype()}
  def extensions, do: %{}

  @doc "Returns runtime shebang overrides. Registered language definitions live in `Minga.Language.Registry`, so this map is empty in normal builds."
  @spec shebang_interpreters() :: %{String.t() => filetype()}
  def shebang_interpreters, do: %{}

  # ── Private ────────────────────────────────────────────────────────────────

  @spec lookup_lang_registry_filename(String.t()) :: filetype() | :miss
  defp lookup_lang_registry_filename(basename) do
    case LangRegistry.for_filename(basename) do
      %{name: name} -> name
      nil -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @spec lookup_lang_registry_extension(String.t()) :: filetype() | :miss
  defp lookup_lang_registry_extension(basename) do
    case Path.extname(basename) do
      "" ->
        :miss

      "." <> ext ->
        case LangRegistry.for_extension(String.downcase(ext)) do
          %{name: name} -> name
          nil -> :miss
        end
    end
  rescue
    ArgumentError -> :miss
  end

  @spec lookup_registry_filename(String.t()) :: filetype() | :miss
  defp lookup_registry_filename(basename) do
    case Minga.Language.Filetype.Registry.lookup_filename(basename) do
      nil -> :miss
      filetype -> filetype
    end
  rescue
    ArgumentError -> :miss
  end

  @spec lookup_registry_extension(String.t()) :: filetype() | :miss
  defp lookup_registry_extension(basename) do
    case Path.extname(basename) do
      "" ->
        :miss

      "." <> ext ->
        case Minga.Language.Filetype.Registry.lookup_extension(String.downcase(ext)) do
          nil -> :miss
          filetype -> filetype
        end
    end
  rescue
    ArgumentError -> :miss
  end

  @spec detect_env_pattern(String.t()) :: filetype() | :miss
  defp detect_env_pattern(".env" <> _rest), do: lookup_lang_registry_bash()
  defp detect_env_pattern(_basename), do: :miss

  @spec lookup_lang_registry_bash() :: filetype() | :miss
  defp lookup_lang_registry_bash do
    case LangRegistry.get(:bash) do
      %{name: :bash} -> :bash
      nil -> :miss
    end
  end

  @spec parse_shebang(String.t() | nil) :: filetype()
  defp parse_shebang(nil), do: :text
  defp parse_shebang(""), do: :text

  defp parse_shebang("#!" <> rest) do
    interpreter =
      rest
      |> String.trim()
      |> extract_interpreter()

    case Minga.Language.Filetype.Registry.lookup_shebang(interpreter) do
      nil -> lookup_lang_registry_shebang(interpreter)
      filetype -> filetype
    end
  end

  defp parse_shebang(_), do: :text

  @spec lookup_lang_registry_shebang(String.t()) :: filetype()
  defp lookup_lang_registry_shebang(interpreter) do
    case LangRegistry.for_shebang(interpreter) do
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
