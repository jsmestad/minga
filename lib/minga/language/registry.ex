defmodule Minga.Language.Registry do
  @moduledoc """
  Single authority for language definitions and filetype detection overrides.

  Backed by ETS with `read_concurrency: true` for lock-free reads on every keystroke, render frame, and comment toggle. Each lookup key stores the language (or override filetype) and its contribution source in the same row. The GenServer owns the table lifecycle; reads go directly to ETS.

  ## Language lookups

  - `get/1` — lookup by language name atom (e.g., `:elixir`)
  - `for_extension/1` — lookup by file extension string (e.g., `"ex"`)
  - `for_filename/1` — lookup by exact filename (e.g., `"Makefile"`)
  - `for_shebang/1` — lookup by shebang interpreter (e.g., `"python3"`)

  ## Runtime overrides

  Config and extensions register lightweight filetype overrides via `register_override/2` and `register_shebang_override/2`. Override entries map a pattern directly to a filetype atom without requiring a full `%Minga.Language{}` definition. They live in a separate key namespace (`{:override_ext, _}`, `{:override_filename, _}`, `{:override_shebang, _}`) so they never collide with language-pack entries. Detection checks overrides first, then falls back to language-pack entries.

  Overrides are source-tagged for group removal: `unregister_source/1` removes both language definitions and overrides from the given source, while leaving entries from other sources intact.

  ## Language registration

  Extensions register languages via `register/2` with `{:extension, name}` as the source. Reload and unload paths remove the whole `%Minga.Language{}` record, so its names, extensions, filenames, shebangs, devicons, grammar metadata, formatter, and LSP defaults disappear together.

  ## Private tables

  Every public function has a version that uses the application table and a version that takes an explicit table name as its last argument. Production callers use the short form. Tests start a private registry with a unique `:name` and `:table` (see `start_link/1`) and pass that table, so they never mutate the application registry and can run concurrently. This follows `Minga.Config.Advice` and `Minga.Popup.Registry`.
  """

  use GenServer

  alias Minga.Language

  @table :minga_language_registry

  # Canonical tree-sitter grammar aliases generated from
  # `config/language_aliases.json` by `mix language_aliases.gen`.
  @grammar_aliases Minga.Language.GeneratedAliases.grammar_aliases()

  @typedoc "Source that contributed registry entries."
  @type contribution_source :: :builtin | :config | :runtime | {:extension, atom()}

  @type register_error :: {:duplicate_key, term(), contribution_source(), contribution_source()}

  @typedoc "Name of the ETS table that backs a registry instance."
  @type table :: atom()

  # ── Client API ─────────────────────────────────────────────────────────────

  @doc """
  Starts the language registry.

  Options:
  - `:name`: process name, defaults to `#{inspect(__MODULE__)}`
  - `:table`: ETS table name, defaults to `default_table/0`
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the ETS table name used by the application registry."
  @spec default_table() :: table()
  def default_table, do: @table

  @doc """
  Returns the language definition for a name atom, or `nil` if unknown.

  ## Examples

      iex> lang = Minga.Language.Registry.get(:elixir)
      iex> lang.label
      "Elixir"

      iex> Minga.Language.Registry.get(:unknown_language)
      nil
  """
  @spec get(atom(), table()) :: Language.t() | nil
  def get(name, table \\ @table) when is_atom(name) and is_atom(table),
    do: lookup_language({:name, name}, table)

  @doc """
  Returns the canonical tree-sitter grammar name for a language label.

  Resolves short or alternate fence labels (e.g. `"js"`, `"c++"`, `"py3"`) to
  the canonical grammar name we ship (e.g. `"javascript"`, `"cpp"`, `"python"`).
  Matching is case-insensitive. Labels that are already canonical, or that have
  no alias, are returned unchanged (lower-cased). This is the single source of
  truth for grammar-name aliasing on the Elixir side.

  ## Examples

      iex> Minga.Language.Registry.canonical_grammar("js")
      "javascript"

      iex> Minga.Language.Registry.canonical_grammar("C++")
      "cpp"

      iex> Minga.Language.Registry.canonical_grammar("elixir")
      "elixir"
  """
  @spec canonical_grammar(String.t()) :: String.t()
  def canonical_grammar(label) when is_binary(label) do
    key = String.downcase(label)
    Map.get(@grammar_aliases, key, key)
  end

  @doc "Returns the canonical grammar alias map (label => grammar name)."
  @spec grammar_aliases() :: %{String.t() => String.t()}
  def grammar_aliases, do: @grammar_aliases

  @doc """
  Returns the language definition for a file extension, or `nil`.

  The extension should not include the leading dot and is matched
  case-insensitively.

  ## Examples

      iex> lang = Minga.Language.Registry.for_extension("ex")
      iex> lang.name
      :elixir
  """
  @spec for_extension(String.t(), table()) :: Language.t() | nil
  def for_extension(ext, table \\ @table) when is_binary(ext) and is_atom(table),
    do: lookup_language({:ext, String.downcase(ext)}, table)

  @doc """
  Returns the language definition for an exact filename, or `nil`.

  ## Examples

      iex> lang = Minga.Language.Registry.for_filename("Makefile")
      iex> lang.name
      :make
  """
  @spec for_filename(String.t(), table()) :: Language.t() | nil
  def for_filename(filename, table \\ @table) when is_binary(filename) and is_atom(table),
    do: lookup_language({:filename, filename}, table)

  @doc """
  Returns the language definition for a shebang interpreter, or `nil`.

  ## Examples

      iex> lang = Minga.Language.Registry.for_shebang("python3")
      iex> lang.name
      :python
  """
  @spec for_shebang(String.t(), table()) :: Language.t() | nil
  def for_shebang(interpreter, table \\ @table) when is_binary(interpreter) and is_atom(table),
    do: lookup_language({:shebang, interpreter}, table)

  # ── Runtime override API ───────────────────────────────────────────────────

  @doc """
  Registers a runtime filetype override for an extension or exact filename.

  `pattern` can be:
  - An extension string starting with `.` (e.g., `".astro"`), case-insensitive
  - An exact filename string (e.g., `"Justfile"`), case-sensitive

  Pass `nil` as the filetype to remove the override.

  ## Examples

      Minga.Language.Registry.register_override(".astro", :astro)
      Minga.Language.Registry.register_override("Justfile", :just)
      Minga.Language.Registry.register_override(".astro", nil)
  """
  @spec register_override(String.t(), atom() | nil) :: :ok
  def register_override(pattern, filetype), do: register_override(pattern, filetype, :runtime)

  @doc "Registers a filetype override with an explicit source, in the given registry table."
  @spec register_override(String.t(), atom() | nil, contribution_source(), table()) :: :ok
  def register_override(pattern, filetype, source, table \\ @table)

  def register_override("." <> ext, nil, _source, table) do
    :ets.delete(table, {:override_ext, String.downcase(ext)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def register_override("." <> ext, filetype, source, table) when is_atom(filetype) do
    :ets.insert(table, {{:override_ext, String.downcase(ext)}, filetype, source})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def register_override(filename, nil, _source, table) when is_binary(filename) do
    :ets.delete(table, {:override_filename, filename})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def register_override(filename, filetype, source, table)
      when is_binary(filename) and is_atom(filetype) do
    :ets.insert(table, {{:override_filename, filename}, filetype, source})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Registers a runtime shebang interpreter override.

  `interpreter` is the basename of the interpreter (e.g., `"deno"`). Pass `nil` to remove.
  """
  @spec register_shebang_override(String.t(), atom() | nil) :: :ok
  def register_shebang_override(interpreter, filetype),
    do: register_shebang_override(interpreter, filetype, :runtime)

  @doc "Registers a shebang override with an explicit source, in the given registry table."
  @spec register_shebang_override(String.t(), atom() | nil, contribution_source(), table()) :: :ok
  def register_shebang_override(interpreter, filetype, source, table \\ @table)

  def register_shebang_override(interpreter, nil, _source, table) when is_binary(interpreter) do
    :ets.delete(table, {:override_shebang, interpreter})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def register_shebang_override(interpreter, filetype, source, table)
      when is_binary(interpreter) and is_atom(filetype) do
    :ets.insert(table, {{:override_shebang, interpreter}, filetype, source})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Returns the override filetype for a file extension (without dot, already downcased), or `nil`."
  @spec lookup_override_extension(String.t(), table()) :: atom() | nil
  def lookup_override_extension(ext, table \\ @table) when is_binary(ext) and is_atom(table) do
    :ets.lookup_element(table, {:override_ext, ext}, 2, nil)
  rescue
    ArgumentError -> nil
  end

  @doc "Returns the override filetype for an exact filename, or `nil`."
  @spec lookup_override_filename(String.t(), table()) :: atom() | nil
  def lookup_override_filename(filename, table \\ @table)
      when is_binary(filename) and is_atom(table) do
    :ets.lookup_element(table, {:override_filename, filename}, 2, nil)
  rescue
    ArgumentError -> nil
  end

  @doc "Returns the override filetype for a shebang interpreter, or `nil`."
  @spec lookup_override_shebang(String.t(), table()) :: atom() | nil
  def lookup_override_shebang(interpreter, table \\ @table)
      when is_binary(interpreter) and is_atom(table) do
    :ets.lookup_element(table, {:override_shebang, interpreter}, 2, nil)
  rescue
    ArgumentError -> nil
  end

  @doc """
  Returns all extension and filename overrides in one read, for batch detection.

  Returns a map with `:extensions` and `:filenames` keys, each mapping pattern strings to filetype atoms.
  """
  @spec override_path_entries(table()) :: %{
          extensions: %{String.t() => atom()},
          filenames: %{String.t() => atom()}
        }
  def override_path_entries(table \\ @table) when is_atom(table) do
    exts = :ets.select(table, [{{{:override_ext, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])

    fnames =
      :ets.select(table, [{{{:override_filename, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])

    %{extensions: Map.new(exts), filenames: Map.new(fnames)}
  rescue
    ArgumentError -> %{extensions: %{}, filenames: %{}}
  end

  # ── Language catalog API ──────────────────────────────────────────────────

  @doc """
  Returns all registered language definitions.
  """
  @spec all(table()) :: [Language.t()]
  def all(table \\ @table) when is_atom(table) do
    :ets.select(table, [{{{:name, :_}, :"$1", :_}, [], [:"$1"]}])
  rescue
    ArgumentError -> []
  end

  @doc """
  Returns all language names that have definitions.
  """
  @spec supported_names(table()) :: [atom()]
  def supported_names(table \\ @table) when is_atom(table) do
    :ets.select(table, [{{{:name, :"$1"}, :_, :_}, [], [:"$1"]}])
  rescue
    ArgumentError -> []
  end

  @doc """
  Registers a config-owned language at runtime.

  Rebuilds the extension, filename, and shebang index entries and records source ownership so reloads and extension unloads can remove contributed data as a group.
  """
  @spec register(Language.t()) :: :ok | {:error, register_error()}
  def register(%Language{} = lang), do: register(lang, :config)

  @doc "Registers a language with an explicit source, in the given registry table."
  @spec register(Language.t(), contribution_source(), table()) ::
          :ok | {:error, register_error()}
  def register(%Language{} = lang, source, table \\ @table) when is_atom(table) do
    keys = Language.identity_keys(lang)

    with :ok <- validate_source_keys(keys, source, table) do
      case get(lang.name, table) do
        %Language{} = old -> remove_index_entries(old, table)
        nil -> :ok
      end

      Enum.each(keys, &:ets.insert(table, {&1, lang, source}))
    end
  end

  @doc "Returns the contribution source for a registry key, or `nil` if the key is unknown."
  @spec source_for(term(), table()) :: contribution_source() | nil
  def source_for(key, table \\ @table) when is_atom(table) do
    :ets.lookup_element(table, key, 3, nil)
  rescue
    ArgumentError -> nil
  end

  @doc "Removes every language and lookup index contributed by a source."
  @spec unregister_source(contribution_source(), table()) :: :ok
  def unregister_source(source, table \\ @table) when is_atom(table) do
    :ets.select_delete(table, [{{:_, :_, :"$1"}, [{:"=:=", :"$1", {:const, source}}], [true]}])
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, :no_state}
  def init(opts) do
    :ets.new(Keyword.get(opts, :table, @table), [
      :named_table,
      :set,
      :public,
      read_concurrency: true
    ])

    {:ok, :no_state}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec lookup_language(term(), table()) :: Language.t() | nil
  defp lookup_language(key, table) do
    :ets.lookup_element(table, key, 2, nil)
  rescue
    ArgumentError -> nil
  end

  @spec validate_source_keys([term()], contribution_source(), table()) ::
          :ok | {:error, register_error()}
  defp validate_source_keys(keys, source, table) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case :ets.lookup_element(table, key, 3, nil) do
        nil -> {:cont, :ok}
        ^source -> {:cont, :ok}
        existing_source -> {:halt, {:error, {:duplicate_key, key, existing_source, source}}}
      end
    end)
  end

  @spec remove_index_entries(Language.t(), table()) :: :ok
  defp remove_index_entries(%Language{} = lang, table) do
    [{:name, _} | secondary_keys] = Language.identity_keys(lang)
    Enum.each(secondary_keys, &:ets.delete(table, &1))
  end
end
