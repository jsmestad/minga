defmodule Minga.Language.Registry do
  @moduledoc """
  Collects all language definitions at startup and provides O(1) lookups.

  Backed by ETS with `read_concurrency: true` for lock-free reads on
  every keystroke, render frame, and comment toggle. The GenServer exists
  only to own the ETS table lifecycle. All reads go directly to ETS.

  ## Lookup functions

  - `get/1` — lookup by language name atom (e.g., `:elixir`)
  - `for_extension/1` — lookup by file extension string (e.g., `"ex"`)
  - `for_filename/1` — lookup by exact filename (e.g., `"Makefile"`)
  - `for_shebang/1` — lookup by shebang interpreter (e.g., `"python3"`)

  ## Runtime registration

  Extensions register new languages via `register/1`. Runtime
  registrations override built-in definitions for the same name.
  """

  use GenServer

  alias Minga.Language

  @table :minga_language_registry

  # All built-in language definition modules. Add new languages here.
  @language_modules [
    Minga.Language.Bash,
    Minga.Language.C,
    Minga.Language.Conf,
    Minga.Language.Cpp,
    Minga.Language.CSharp,
    Minga.Language.Css,
    Minga.Language.Csv,
    Minga.Language.Dart,
    Minga.Language.Diff,
    Minga.Language.Dockerfile,
    Minga.Language.EditorConfig,
    Minga.Language.Elixir,
    Minga.Language.EmacsLisp,
    Minga.Language.Erlang,
    Minga.Language.Fish,
    Minga.Language.GitConfig,
    Minga.Language.Gleam,
    Minga.Language.Go,
    Minga.Language.GraphQL,
    Minga.Language.Haskell,
    Minga.Language.Hcl,
    Minga.Language.Heex,
    Minga.Language.Html,
    Minga.Language.Ini,
    Minga.Language.Java,
    Minga.Language.JavaScript,
    Minga.Language.JavaScriptReact,
    Minga.Language.Json,
    Minga.Language.Kotlin,
    Minga.Language.Lfe,
    Minga.Language.Lua,
    Minga.Language.Make,
    Minga.Language.Markdown,
    Minga.Language.Nix,
    Minga.Language.OCaml,
    Minga.Language.Perl,
    Minga.Language.Php,
    Minga.Language.Protobuf,
    Minga.Language.Python,
    Minga.Language.R,
    Minga.Language.Ruby,
    Minga.Language.Rust,
    Minga.Language.Scala,
    Minga.Language.Scss,
    Minga.Language.Sql,
    Minga.Language.Swift,
    Minga.Language.Text,
    Minga.Language.Toml,
    Minga.Language.TypeScript,
    Minga.Language.TypeScriptReact,
    Minga.Language.Vim,
    Minga.Language.Xml,
    Minga.Language.Yaml,
    Minga.Language.Zig
  ]

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
  Registers a language at runtime (for extensions).

  Overwrites any existing definition for the same name. Rebuilds
  the extension, filename, and shebang index entries.
  """
  @spec register(Language.t()) :: :ok
  def register(%Language{} = lang) do
    # Remove stale index entries from the old definition before inserting
    case get(lang.name) do
      %Language{} = old -> remove_index_entries(old)
      nil -> :ok
    end

    insert_language(lang)
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

    for mod <- @language_modules do
      lang = mod.definition()
      insert_language(lang)
    end

    {:ok, :no_state}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec remove_index_entries(Language.t()) :: :ok
  defp remove_index_entries(%Language{} = lang) do
    for ext <- lang.extensions, do: :ets.delete(@table, {:ext, String.downcase(ext)})
    for filename <- lang.filenames, do: :ets.delete(@table, {:filename, filename})
    for interpreter <- lang.shebangs, do: :ets.delete(@table, {:shebang, interpreter})
    :ok
  end

  @spec insert_language(Language.t()) :: :ok
  defp insert_language(%Language{} = lang) do
    # Primary lookup by name
    :ets.insert(@table, {{:name, lang.name}, lang})

    # Index by extension
    for ext <- lang.extensions do
      :ets.insert(@table, {{:ext, String.downcase(ext)}, lang})
    end

    # Index by filename
    for filename <- lang.filenames do
      :ets.insert(@table, {{:filename, filename}, lang})
    end

    # Index by shebang interpreter
    for interpreter <- lang.shebangs do
      :ets.insert(@table, {{:shebang, interpreter}, lang})
    end

    :ok
  end
end
