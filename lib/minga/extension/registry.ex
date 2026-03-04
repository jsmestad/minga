defmodule Minga.Extension.Registry do
  @moduledoc """
  Agent-based registry for declared extensions.

  Tracks which extensions have been declared in config, their paths,
  config options, runtime status, and supervisor pids. Other modules
  query this registry to list, start, or stop extensions.
  """

  use Agent

  alias Minga.Extension

  @typedoc "Registry entry for a single extension."
  @type entry :: %{
          module: module() | nil,
          path: String.t(),
          config: keyword(),
          status: Extension.extension_status(),
          pid: pid() | nil
        }

  @typedoc "Internal state: extension name → entry."
  @type state :: %{atom() => entry()}

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Starts the extension registry."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @doc """
  Registers an extension declaration.

  Called by the config DSL when `extension :name, path: "..."` is evaluated.
  The extension is not started yet; it's just recorded for later loading.
  """
  @spec register(atom(), String.t(), keyword()) :: :ok
  @spec register(GenServer.server(), atom(), String.t(), keyword()) :: :ok
  def register(name, path, config) when is_atom(name) and is_binary(path),
    do: register(__MODULE__, name, path, config)

  def register(server, name, path, config)
      when is_atom(name) and is_binary(path) and is_list(config) do
    entry = %{
      module: nil,
      path: path,
      config: config,
      status: :stopped,
      pid: nil
    }

    Agent.update(server, &Map.put(&1, name, entry))
  end

  @doc "Removes an extension from the registry."
  @spec unregister(atom()) :: :ok
  @spec unregister(GenServer.server(), atom()) :: :ok
  def unregister(name) when is_atom(name), do: unregister(__MODULE__, name)

  def unregister(server, name) when is_atom(name) do
    Agent.update(server, &Map.delete(&1, name))
  end

  @doc "Returns all registered extensions as a list of `{name, entry}` tuples."
  @spec all() :: [{atom(), entry()}]
  @spec all(GenServer.server()) :: [{atom(), entry()}]
  def all, do: all(__MODULE__)

  def all(server) do
    Agent.get(server, &Map.to_list(&1))
  end

  @doc "Returns the entry for a single extension, or `:error` if not registered."
  @spec get(atom()) :: {:ok, entry()} | :error
  @spec get(GenServer.server(), atom()) :: {:ok, entry()} | :error
  def get(name) when is_atom(name), do: get(__MODULE__, name)

  def get(server, name) when is_atom(name) do
    Agent.get(server, &Map.fetch(&1, name))
  end

  @doc "Updates fields on an existing extension entry."
  @spec update(atom(), keyword()) :: :ok
  @spec update(GenServer.server(), atom(), keyword()) :: :ok
  def update(name, updates) when is_atom(name) and is_list(updates),
    do: update(__MODULE__, name, updates)

  def update(server, name, updates) when is_atom(name) and is_list(updates) do
    Agent.update(server, &apply_updates(&1, name, updates))
  end

  @spec apply_updates(state(), atom(), keyword()) :: state()
  defp apply_updates(state, name, updates) do
    case Map.fetch(state, name) do
      {:ok, entry} ->
        updated = Enum.reduce(updates, entry, fn {k, v}, acc -> Map.put(acc, k, v) end)
        Map.put(state, name, updated)

      :error ->
        state
    end
  end

  @doc "Removes all registered extensions."
  @spec reset() :: :ok
  @spec reset(GenServer.server()) :: :ok
  def reset, do: reset(__MODULE__)
  def reset(server), do: Agent.update(server, fn _ -> %{} end)
end
