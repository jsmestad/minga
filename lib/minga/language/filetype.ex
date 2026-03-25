defmodule Minga.Language.Filetype do
  @moduledoc """
  Detects a file's language from its path and content.

  Detection priority (matching Neovim):
  1. Exact filename match (case-sensitive)
  2. File extension (case-insensitive)
  3. `.env*` / `.envrc*` pattern → `:bash`
  4. Shebang line from first line of content
  5. Fall back to `:text`

  This module is pure — no GenServer, no side effects. For runtime
  extensibility (adding new patterns), see `Minga.Language.Filetype.Registry`.
  """

  # ── Exact filename → filetype (case-sensitive) ─────────────────────────────

  @filenames %{
    "Makefile" => :make,
    "GNUmakefile" => :make,
    "Dockerfile" => :dockerfile,
    "Gemfile" => :ruby,
    "Rakefile" => :ruby,
    "Brewfile" => :ruby,
    ".gitignore" => :gitconfig,
    ".gitattributes" => :gitconfig,
    ".gitmodules" => :gitconfig,
    ".editorconfig" => :editorconfig,
    "mix.lock" => :elixir,
    "rebar.config" => :erlang,
    "rebar.lock" => :erlang
  }

  # ── Extension → filetype (looked up after downcasing) ──────────────────────

  @extensions %{
    "ex" => :elixir,
    "exs" => :elixir,
    "erl" => :erlang,
    "hrl" => :erlang,
    "heex" => :heex,
    "leex" => :heex,
    "rb" => :ruby,
    "rake" => :ruby,
    "gemspec" => :ruby,
    "js" => :javascript,
    "mjs" => :javascript,
    "cjs" => :javascript,
    "ts" => :typescript,
    "mts" => :typescript,
    "cts" => :typescript,
    "jsx" => :javascript_react,
    "tsx" => :typescript_react,
    "go" => :go,
    "rs" => :rust,
    "zig" => :zig,
    "zon" => :zig,
    "c" => :c,
    "h" => :c,
    "cpp" => :cpp,
    "cc" => :cpp,
    "cxx" => :cpp,
    "hpp" => :cpp,
    "lua" => :lua,
    "py" => :python,
    "pyi" => :python,
    "sh" => :bash,
    "bash" => :bash,
    "zsh" => :bash,
    "fish" => :fish,
    "html" => :html,
    "htm" => :html,
    "css" => :css,
    "scss" => :scss,
    "sass" => :scss,
    "json" => :json,
    "jsonc" => :json,
    "yaml" => :yaml,
    "yml" => :yaml,
    "toml" => :toml,
    "md" => :markdown,
    "markdown" => :markdown,
    "sql" => :sql,
    "graphql" => :graphql,
    "gql" => :graphql,
    "kt" => :kotlin,
    "kts" => :kotlin,
    "gleam" => :gleam,
    "dockerfile" => :dockerfile,
    "el" => :emacs_lisp,
    "lfe" => :lfe,
    "xml" => :xml,
    "svg" => :xml,
    "txt" => :text,
    "csv" => :csv,
    "tsv" => :csv,
    "vim" => :vim,
    "diff" => :diff,
    "patch" => :diff,
    "ini" => :ini,
    "conf" => :conf,
    "cfg" => :conf,
    "nix" => :nix,
    "proto" => :protobuf,
    "java" => :java,
    "swift" => :swift,
    "r" => :r,
    "rmd" => :r,
    "cs" => :c_sharp,
    "csx" => :c_sharp,
    "php" => :php,
    "phtml" => :php,
    "tf" => :hcl,
    "tfvars" => :hcl,
    "hcl" => :hcl,
    "ml" => :ocaml,
    "mli" => :ocaml,
    "hs" => :haskell,
    "lhs" => :haskell,
    "scala" => :scala,
    "sbt" => :scala,
    "sc" => :scala,
    "dart" => :dart,
    "mk" => :make,
    "mak" => :make
  }

  # ── Shebang interpreter → filetype ────────────────────────────────────────

  @shebang_interpreters %{
    "ruby" => :ruby,
    "python" => :python,
    "python3" => :python,
    "node" => :javascript,
    "bash" => :bash,
    "sh" => :bash,
    "zsh" => :bash,
    "fish" => :fish,
    "perl" => :perl,
    "elixir" => :elixir,
    "escript" => :erlang,
    "lua" => :lua
  }

  @typedoc "A language identifier atom."
  @type filetype :: atom()

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Detects the language of a file from its path alone.

  Checks exact filename (case-sensitive), then extension (case-insensitive),
  then `.env*`/`.envrc*` patterns. Returns `:text` if nothing matches.
  """
  alias Minga.Language.Registry, as: LangRegistry

  @spec detect(String.t() | nil) :: filetype()
  def detect(nil), do: :text

  def detect(file_path) when is_binary(file_path) do
    basename = Path.basename(file_path)

    with :miss <- lookup_registry_filename(basename),
         :miss <- lookup_registry_extension(basename),
         :miss <- lookup_lang_registry_filename(basename),
         :miss <- lookup_lang_registry_extension(basename),
         :miss <- detect_env_pattern(basename) do
      :text
    end
  end

  @doc """
  Detects the language from a file path and the first line of content.

  Tries `detect/1` first. If that returns `:text`, attempts shebang
  detection from `first_line`. Returns `:text` if nothing matches.
  """
  @spec detect_from_content(String.t() | nil, String.t() | nil) :: filetype()
  def detect_from_content(file_path, first_line) do
    case detect(file_path) do
      :text -> parse_shebang(first_line)
      filetype -> filetype
    end
  end

  @doc "Returns the hardcoded filename → filetype map."
  @spec filenames() :: %{String.t() => filetype()}
  def filenames, do: @filenames

  @doc "Returns the hardcoded extension → filetype map."
  @spec extensions() :: %{String.t() => filetype()}
  def extensions, do: @extensions

  @doc "Returns the hardcoded shebang interpreter → filetype map."
  @spec shebang_interpreters() :: %{String.t() => filetype()}
  def shebang_interpreters, do: @shebang_interpreters

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
  defp detect_env_pattern(basename) do
    cond do
      String.starts_with?(basename, ".env") -> :bash
      String.starts_with?(basename, ".envrc") -> :bash
      true -> :miss
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

    # Check Filetype.Registry first (runtime overrides), then Language registry,
    # then fall back to the compile-time map for any stragglers
    case Minga.Language.Filetype.Registry.lookup_shebang(interpreter) do
      nil ->
        case LangRegistry.for_shebang(interpreter) do
          %{name: name} -> name
          nil -> Map.get(@shebang_interpreters, interpreter, :text)
        end

      filetype ->
        filetype
    end
  end

  defp parse_shebang(_), do: :text

  @spec extract_interpreter(String.t()) :: String.t()
  defp extract_interpreter(shebang_path) do
    parts = String.split(shebang_path)

    case parts do
      # #!/usr/bin/env ruby
      [_env_path, interpreter | _] ->
        Path.basename(interpreter)

      # #!/usr/bin/ruby
      [path | _] ->
        Path.basename(path)

      [] ->
        ""
    end
  end
end
