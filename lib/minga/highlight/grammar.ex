defmodule Minga.Highlight.Grammar do
  @moduledoc """
  Maps filetypes to tree-sitter language names and locates highlight queries.

  Filetypes (atoms from `Minga.Filetype`) map to tree-sitter grammar names
  (strings matching Zig's compiled-in registry). Highlight queries are loaded
  from `priv/queries/{language}/highlights.scm` with an optional user override
  in `~/.config/minga/queries/{language}/highlights.scm`.
  """

  @filetype_to_language %{
    elixir: "elixir",
    erlang: "erlang",
    heex: "heex",
    ruby: "ruby",
    javascript: "javascript",
    javascript_react: "javascript",
    typescript: "typescript",
    typescript_react: "tsx",
    go: "go",
    rust: "rust",
    zig: "zig",
    c: "c",
    cpp: "cpp",
    python: "python",
    lua: "lua",
    bash: "bash",
    html: "html",
    css: "css",
    json: "json",
    yaml: "yaml",
    toml: "toml",
    markdown: "markdown",
    kotlin: "kotlin",
    gleam: "gleam"
  }

  @typedoc "A tree-sitter language name."
  @type language :: String.t()

  @doc """
  Returns the tree-sitter language name for a filetype atom.

  ## Examples

      iex> Minga.Highlight.Grammar.language_for_filetype(:elixir)
      {:ok, "elixir"}

      iex> Minga.Highlight.Grammar.language_for_filetype(:typescript_react)
      {:ok, "tsx"}

      iex> Minga.Highlight.Grammar.language_for_filetype(:text)
      :unsupported
  """
  @spec language_for_filetype(atom()) :: {:ok, language()} | :unsupported
  def language_for_filetype(filetype) when is_atom(filetype) do
    case Map.get(@filetype_to_language, filetype) do
      nil -> :unsupported
      lang -> {:ok, lang}
    end
  end

  @doc """
  Returns the path to the highlight query file for a language.

  Checks user config dir first (`~/.config/minga/queries/{lang}/highlights.scm`),
  then falls back to `priv/queries/{lang}/highlights.scm`.

  Returns `nil` if no query file exists.
  """
  @spec query_path(language()) :: String.t() | nil
  def query_path(language) when is_binary(language) do
    user_path = user_query_path(language)
    priv_path = priv_query_path(language)

    cond do
      user_path != nil and File.exists?(user_path) -> user_path
      File.exists?(priv_path) -> priv_path
      true -> nil
    end
  end

  @doc """
  Reads the highlight query content for a language.

  Returns `{:ok, query_text}` or `{:error, reason}`.
  """
  @spec read_query(language()) :: {:ok, String.t()} | {:error, :no_query | File.posix()}
  def read_query(language) when is_binary(language) do
    case query_path(language) do
      nil -> {:error, :no_query}
      path -> File.read(path)
    end
  end

  @doc """
  Returns the expected path for a dynamically-loaded grammar shared library.

  Path: `~/.config/minga/grammars/{name}.so` (or `.dylib` on macOS).
  """
  @spec dynamic_grammar_path(String.t()) :: String.t()
  def dynamic_grammar_path(name) when is_binary(name) do
    ext = if :os.type() == {:unix, :darwin}, do: "dylib", else: "so"
    config_dir = Path.join([System.user_home!(), ".config", "minga", "grammars"])
    Path.join(config_dir, "#{name}.#{ext}")
  end

  @doc "Returns the full filetype-to-language mapping."
  @spec supported_languages() :: %{atom() => language()}
  def supported_languages, do: @filetype_to_language

  # ── Private ──

  @spec priv_query_path(language()) :: String.t()
  defp priv_query_path(language) do
    Path.join([:code.priv_dir(:minga), "queries", language, "highlights.scm"])
  end

  @spec user_query_path(language()) :: String.t() | nil
  defp user_query_path(language) do
    case System.user_home() do
      nil -> nil
      home -> Path.join([home, ".config", "minga", "queries", language, "highlights.scm"])
    end
  end
end
