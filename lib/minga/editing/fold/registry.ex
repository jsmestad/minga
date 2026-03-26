defmodule Minga.Editing.Fold.Registry do
  @moduledoc """
  Registry for fold range providers.

  Stores provider modules in an ETS table with `read_concurrency: true`
  for fast lookups on the render path. Providers register by filetype;
  the registry returns all providers that handle a given filetype.

  Started as part of the supervision tree. Extensions register providers
  at load time via `register/2`.
  """

  use GenServer

  @table :minga_fold_providers

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc "Starts the fold registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a fold provider module.

  The module must implement the `Minga.Editing.Fold.Provider` behaviour. Its
  `filetypes/0` callback is called to determine which filetypes it
  handles.
  """
  @spec register(module()) :: :ok
  def register(provider_module) when is_atom(provider_module) do
    GenServer.call(__MODULE__, {:register, provider_module})
  end

  @doc """
  Returns all provider modules that handle the given filetype.

  Includes providers registered for `:all` filetypes and providers
  registered for the specific filetype.
  """
  @spec providers_for(atom()) :: [module()]
  def providers_for(filetype) when is_atom(filetype) do
    specific = lookup(filetype)
    wildcard = lookup(:all)
    Enum.uniq(specific ++ wildcard)
  end

  @doc """
  Returns all registered provider modules.
  """
  @spec all_providers() :: [module()]
  def all_providers do
    case :ets.info(@table) do
      :undefined ->
        []

      _ ->
        @table
        |> :ets.tab2list()
        |> Enum.flat_map(fn {_filetype, modules} -> modules end)
        |> Enum.uniq()
    end
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, provider_module}, _from, state) do
    filetypes = provider_module.filetypes()

    case filetypes do
      :all ->
        add_provider(:all, provider_module)

      types when is_list(types) ->
        Enum.each(types, &add_provider(&1, provider_module))
    end

    {:reply, :ok, state}
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec lookup(atom()) :: [module()]
  defp lookup(filetype) do
    case :ets.lookup(@table, filetype) do
      [{^filetype, modules}] -> modules
      [] -> []
    end
  end

  @spec add_provider(atom(), module()) :: true
  defp add_provider(filetype, module) do
    existing = lookup(filetype)

    unless module in existing do
      :ets.insert(@table, {filetype, [module | existing]})
    end

    true
  end
end
