defmodule Minga.Language.Registry do
  @moduledoc """
  Provides O(1) language catalog lookups for `%Minga.Language{}` definitions registered by config and extension-owned language packs.

  Backed by ETS with `read_concurrency: true` for lock-free reads on every keystroke, render frame, and comment toggle. The GenServer exists only to own the ETS table lifecycle. All reads go directly to ETS.

  ## Lookup functions

  - `get/1` — lookup by language name atom (e.g., `:elixir`)
  - `for_extension/1` — lookup by file extension string (e.g., `"ex"`)
  - `for_filename/1` — lookup by exact filename (e.g., `"Makefile"`)
  - `for_shebang/1` — lookup by shebang interpreter (e.g., `"python3"`)

  ## Runtime registration

  Extensions register languages via `register/2` with `{:extension, name}` as the source. Reload and unload paths remove the whole `%Minga.Language{}` record, so its names, extensions, filenames, shebangs, devicons, grammar metadata, formatter, and LSP defaults disappear together.
  """

  use GenServer

  alias Minga.Language

  @table :minga_language_registry
  @source_table :minga_language_registry_sources

  @typedoc "Source that contributed registry entries."
  @type contribution_source :: :builtin | :config | {:extension, atom()}

  @type register_error :: {:duplicate_key, term(), contribution_source(), contribution_source()}

  # ── Client API ─────────────────────────────────────────────────────────────

  @doc "Starts the language registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the language definition for a name atom, or `nil` if unknown.

  ## Examples

      iex> lang = Minga.Language.Registry.get(:elixir)
      iex> lang.label
      "Elixir"

      iex> Minga.Language.Registry.get(:unknown_language)
      nil
  """
  @spec get(atom()) :: Language.t() | nil
  def get(name) when is_atom(name) do
    case :ets.lookup(@table, {:name, name}) do
      [{_, lang}] -> lang
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Returns the language definition for a file extension, or `nil`.

  The extension should not include the leading dot and is matched
  case-insensitively.

  ## Examples

      iex> lang = Minga.Language.Registry.for_extension("ex")
      iex> lang.name
      :elixir
  """
  @spec for_extension(String.t()) :: Language.t() | nil
  def for_extension(ext) when is_binary(ext) do
    case :ets.lookup(@table, {:ext, String.downcase(ext)}) do
      [{_, lang}] -> lang
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Returns the language definition for an exact filename, or `nil`.

  ## Examples

      iex> lang = Minga.Language.Registry.for_filename("Makefile")
      iex> lang.name
      :make
  """
  @spec for_filename(String.t()) :: Language.t() | nil
  def for_filename(filename) when is_binary(filename) do
    case :ets.lookup(@table, {:filename, filename}) do
      [{_, lang}] -> lang
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Returns the language definition for a shebang interpreter, or `nil`.

  ## Examples

      iex> lang = Minga.Language.Registry.for_shebang("python3")
      iex> lang.name
      :python
  """
  @spec for_shebang(String.t()) :: Language.t() | nil
  def for_shebang(interpreter) when is_binary(interpreter) do
    case :ets.lookup(@table, {:shebang, interpreter}) do
      [{_, lang}] -> lang
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Returns all registered language definitions.
  """
  @spec all() :: [Language.t()]
  def all do
    @table
    |> :ets.match({{:name, :_}, :"$1"})
    |> List.flatten()
  rescue
    ArgumentError -> []
  end

  @doc """
  Returns all language names that have definitions.
  """
  @spec supported_names() :: [atom()]
  def supported_names do
    @table
    |> :ets.match({{:name, :"$1"}, :_})
    |> List.flatten()
  rescue
    ArgumentError -> []
  end

  @doc """
  Registers a config-owned language at runtime.

  Rebuilds the extension, filename, and shebang index entries and records source ownership so reloads and extension unloads can remove contributed data as a group.
  """
  @spec register(Language.t()) :: :ok | {:error, register_error()}
  def register(%Language{} = lang), do: register(lang, :config)

  @doc "Registers a language with an explicit source."
  @spec register(Language.t(), contribution_source()) :: :ok | {:error, register_error()}
  def register(%Language{} = lang, source) do
    with :ok <- validate_source_keys(lang, source) do
      case get(lang.name) do
        %Language{} = old -> remove_index_entries(old)
        nil -> :ok
      end

      insert_language(lang, source)
      :ok
    end
  end

  @doc "Returns the contribution source for a registry key, or `nil` if the key is unknown."
  @spec source_for(term()) :: contribution_source() | nil
  def source_for(key) do
    ensure_source_table!()

    case :ets.lookup(@source_table, key) do
      [{^key, source}] -> source
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Removes every language and lookup index contributed by a source."
  @spec unregister_source(contribution_source()) :: :ok
  def unregister_source(source) do
    ensure_source_table!()

    @source_table
    |> :ets.tab2list()
    |> Enum.each(fn
      {key, ^source} ->
        :ets.delete(@table, key)
        :ets.delete(@source_table, key)

      _entry ->
        :ok
    end)

    :ok
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, :no_state}
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true
    ])

    :ets.new(@source_table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true
    ])

    {:ok, :no_state}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec validate_source_keys(Language.t(), contribution_source()) ::
          :ok | {:error, register_error()}
  defp validate_source_keys(%Language{} = lang, source) do
    ensure_source_table!()

    lang
    |> language_keys()
    |> Enum.reduce_while(:ok, fn key, :ok -> validate_source_key(key, source) end)
  end

  @spec validate_source_key(term(), contribution_source()) ::
          {:cont, :ok} | {:halt, {:error, register_error()}}
  defp validate_source_key(key, source) do
    case :ets.lookup(@source_table, key) do
      [{^key, ^source}] ->
        {:cont, :ok}

      [{^key, existing_source}] ->
        {:halt, {:error, {:duplicate_key, key, existing_source, source}}}

      [] ->
        {:cont, :ok}
    end
  end

  @spec language_keys(Language.t()) :: [term()]
  defp language_keys(%Language{} = lang) do
    name_key = {:name, lang.name}
    ext_keys = Enum.map(lang.extensions, &{:ext, String.downcase(&1)})
    filename_keys = Enum.map(lang.filenames, &{:filename, &1})
    shebang_keys = Enum.map(lang.shebangs, &{:shebang, &1})
    [name_key | ext_keys ++ filename_keys ++ shebang_keys]
  end

  @spec remove_index_entries(Language.t()) :: :ok
  defp remove_index_entries(%Language{} = lang) do
    for ext <- lang.extensions, do: delete_key({:ext, String.downcase(ext)})
    for filename <- lang.filenames, do: delete_key({:filename, filename})
    for interpreter <- lang.shebangs, do: delete_key({:shebang, interpreter})
    :ok
  end

  @spec insert_language(Language.t(), contribution_source()) :: :ok
  defp insert_language(%Language{} = lang, source) do
    insert_key({:name, lang.name}, lang, source)

    for ext <- lang.extensions do
      insert_key({:ext, String.downcase(ext)}, lang, source)
    end

    for filename <- lang.filenames do
      insert_key({:filename, filename}, lang, source)
    end

    for interpreter <- lang.shebangs do
      insert_key({:shebang, interpreter}, lang, source)
    end

    :ok
  end

  @spec insert_key(term(), Language.t(), contribution_source()) :: true
  defp insert_key(key, lang, source) do
    ensure_source_table!()
    :ets.insert(@table, {key, lang})
    :ets.insert(@source_table, {key, source})
  end

  @spec delete_key(term()) :: true
  defp delete_key(key) do
    ensure_source_table!()
    :ets.delete(@table, key)
    :ets.delete(@source_table, key)
  end

  @spec ensure_source_table!() :: :ok
  defp ensure_source_table! do
    case :ets.info(@source_table) do
      :undefined ->
        :ets.new(@source_table, [:named_table, :set, :public, read_concurrency: true])
        :ok

      _info ->
        :ok
    end
  end
end
