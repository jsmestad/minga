defmodule Minga.Highlight.Grammar do
  @moduledoc """
  Maps filetypes to tree-sitter language names and locates highlight queries.

  Filetypes (atoms from `Minga.Language.Filetype`) map to tree-sitter grammar names
  (strings matching Zig's compiled-in registry). Highlight queries are loaded
  from `priv/queries/{language}/highlights.scm` with an optional user override
  in `~/.config/minga/queries/{language}/highlights.scm`.
  """

  alias Minga.Language.Registry, as: LangRegistry

  @typedoc "A tree-sitter language name."
  @type language :: String.t()

  @doc """
  Initializes the dynamic language registry ETS table.

  Called once at application startup. The table stores runtime-registered
  filetype-to-language mappings from extensions. Lookups check this table
  first, then fall back to the compile-time map.
  """
  @spec init_registry() :: :ok
  def init_registry do
    :ets.new(:minga_grammar_registry, [:named_table, :set, :public, read_concurrency: true])
    :ok
  rescue
    ArgumentError ->
      # Table already exists (e.g., during hot reload)
      :ok
  end

  @doc """
  Registers a dynamic filetype-to-language mapping.

  Extensions call this to make their grammar available for syntax
  highlighting. The mapping is checked before the compile-time defaults,
  so extensions can override built-in grammars.

  ## Examples

      Minga.Highlight.Grammar.register_language(:org, "org")
      Minga.Highlight.Grammar.register_language(:astro, "astro")
  """
  @spec register_language(atom(), String.t()) :: :ok
  def register_language(filetype, language) when is_atom(filetype) and is_binary(language) do
    :ets.insert(:minga_grammar_registry, {filetype, language})
    :ok
  end

  @doc """
  Returns the tree-sitter language name for a filetype atom.

  Checks the dynamic registry (populated by extensions) first, then
  falls back to the compile-time mapping.

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
    case lookup_dynamic(filetype) do
      {:ok, lang} -> {:ok, lang}
      :miss -> lookup_static(filetype)
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
  Returns the path to the injection query file for a language.

  Checks user config dir first (`~/.config/minga/queries/{lang}/injections.scm`),
  then falls back to `priv/queries/{lang}/injections.scm`.

  Returns `nil` if no injection query file exists.
  """
  @spec injection_query_path(language()) :: String.t() | nil
  def injection_query_path(language) when is_binary(language) do
    user_path = user_injection_query_path(language)
    priv_path = priv_injection_query_path(language)

    cond do
      user_path != nil and File.exists?(user_path) -> user_path
      File.exists?(priv_path) -> priv_path
      true -> nil
    end
  end

  @doc """
  Reads the injection query content for a language.

  Returns `{:ok, query_text}` or `{:error, reason}`.
  """
  @spec read_injection_query(language()) :: {:ok, String.t()} | {:error, :no_query | File.posix()}
  def read_injection_query(language) when is_binary(language) do
    case injection_query_path(language) do
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

  @doc """
  Returns the full filetype-to-language mapping, including dynamic registrations.
  """
  @spec supported_languages() :: %{atom() => language()}
  def supported_languages do
    dynamic =
      try do
        :ets.tab2list(:minga_grammar_registry)
        |> Map.new()
      rescue
        ArgumentError -> %{}
      end

    static =
      LangRegistry.all()
      |> Enum.filter(fn lang -> lang.grammar != nil end)
      |> Map.new(fn lang -> {lang.name, lang.grammar} end)

    Map.merge(static, dynamic)
  end

  # ── Private ──

  @spec lookup_dynamic(atom()) :: {:ok, language()} | :miss
  defp lookup_dynamic(filetype) do
    case :ets.lookup(:minga_grammar_registry, filetype) do
      [{^filetype, lang}] -> {:ok, lang}
      [] -> :miss
    end
  rescue
    ArgumentError ->
      # Table doesn't exist yet (e.g., during early startup or tests)
      :miss
  end

  @spec lookup_static(atom()) :: {:ok, language()} | :unsupported
  defp lookup_static(filetype) do
    case LangRegistry.get(filetype) do
      %{grammar: grammar} when is_binary(grammar) -> {:ok, grammar}
      _ -> :unsupported
    end
  end

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

  @spec priv_injection_query_path(language()) :: String.t()
  defp priv_injection_query_path(language) do
    Path.join([:code.priv_dir(:minga), "queries", language, "injections.scm"])
  end

  @spec user_injection_query_path(language()) :: String.t() | nil
  defp user_injection_query_path(language) do
    case System.user_home() do
      nil -> nil
      home -> Path.join([home, ".config", "minga", "queries", language, "injections.scm"])
    end
  end
end
