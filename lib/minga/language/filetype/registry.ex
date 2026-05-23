defmodule Minga.Language.Filetype.Registry do
  @moduledoc """
  Runtime-extensible filetype registry backed by an Agent.

  Starts empty and allows config or extensions to register overrides at runtime via `register/2`. Built-in language filetypes come from `Minga.Language.Registry`, where they are owned by their language pack source.

  ## Examples

      Minga.Language.Filetype.Registry.register(".astro", :astro)
      Minga.Language.Filetype.Registry.register("Justfile", :just)
      :astro = Minga.Language.Filetype.Registry.lookup_extension("astro")
      :just = Minga.Language.Filetype.Registry.lookup_filename("Justfile")
  """

  use Agent

  alias Minga.Language.Filetype

  @typedoc "Registry state: extension map, filename map, shebang map."
  @type state :: %{
          extensions: %{String.t() => Filetype.filetype()},
          filenames: %{String.t() => Filetype.filetype()},
          shebang_interpreters: %{String.t() => Filetype.filetype()}
        }

  # ── Client API ─────────────────────────────────────────────────────────────

  @doc "Starts the registry for runtime filetype overrides."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    Agent.start_link(fn -> empty_state() end, name: name)
  end

  @doc """
  Registers a new filetype mapping.

  `pattern` can be:
  - An extension string starting with `.` (e.g., `".astro"`) — case-insensitive
  - An exact filename string (e.g., `"Justfile"`) — case-sensitive
  """
  @spec register(String.t(), Filetype.filetype() | nil) :: :ok
  def register("." <> ext, nil) do
    Agent.update(__MODULE__, fn state ->
      %{state | extensions: Map.delete(state.extensions, String.downcase(ext))}
    end)
  end

  def register("." <> ext, filetype) when is_atom(filetype) do
    Agent.update(__MODULE__, fn state ->
      %{state | extensions: Map.put(state.extensions, String.downcase(ext), filetype)}
    end)
  end

  def register(filename, nil) when is_binary(filename) do
    Agent.update(__MODULE__, fn state ->
      %{state | filenames: Map.delete(state.filenames, filename)}
    end)
  end

  def register(filename, filetype) when is_binary(filename) and is_atom(filetype) do
    Agent.update(__MODULE__, fn state ->
      %{state | filenames: Map.put(state.filenames, filename, filetype)}
    end)
  end

  @doc """
  Registers a new shebang interpreter mapping.

  `interpreter` is the basename of the interpreter (e.g., `"deno"`).
  """
  @spec register_shebang(String.t(), Filetype.filetype() | nil) :: :ok
  def register_shebang(interpreter, nil) when is_binary(interpreter) do
    Agent.update(__MODULE__, fn state ->
      %{state | shebang_interpreters: Map.delete(state.shebang_interpreters, interpreter)}
    end)
  end

  def register_shebang(interpreter, filetype)
      when is_binary(interpreter) and is_atom(filetype) do
    Agent.update(__MODULE__, fn state ->
      %{state | shebang_interpreters: Map.put(state.shebang_interpreters, interpreter, filetype)}
    end)
  end

  @doc "Looks up a filetype by extension (without the dot, already downcased)."
  @spec lookup_extension(String.t()) :: Filetype.filetype() | nil
  def lookup_extension(ext) when is_binary(ext) do
    Agent.get(__MODULE__, fn state -> Map.get(state.extensions, ext) end)
  end

  @doc "Looks up a filetype by exact filename."
  @spec lookup_filename(String.t()) :: Filetype.filetype() | nil
  def lookup_filename(filename) when is_binary(filename) do
    Agent.get(__MODULE__, fn state -> Map.get(state.filenames, filename) end)
  end

  @doc "Looks up a filetype by shebang interpreter name."
  @spec lookup_shebang(String.t()) :: Filetype.filetype() | nil
  def lookup_shebang(interpreter) when is_binary(interpreter) do
    Agent.get(__MODULE__, fn state -> Map.get(state.shebang_interpreters, interpreter) end)
  end

  @doc "Returns all registered extensions."
  @spec all_extensions() :: %{String.t() => Filetype.filetype()}
  def all_extensions do
    Agent.get(__MODULE__, fn state -> state.extensions end)
  end

  @doc "Returns all registered filenames."
  @spec all_filenames() :: %{String.t() => Filetype.filetype()}
  def all_filenames do
    Agent.get(__MODULE__, fn state -> state.filenames end)
  end

  @spec empty_state() :: state()
  defp empty_state do
    %{extensions: %{}, filenames: %{}, shebang_interpreters: %{}}
  end
end
