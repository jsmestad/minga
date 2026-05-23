defmodule Minga.Extension.Overlay do
  @moduledoc """
  ETS-backed registry for extension-owned overlays on the editor surface.

  Extensions register overlays anchored to buffer positions. The Layer 2
  emit pipeline reads this registry during chrome sync and converts
  buffer positions to screen coordinates for the frontend.

  Overlays are source-tagged for `ContributionCleanup` integration:
  when an extension crashes or reloads, all its overlays are removed
  automatically.
  """

  use GenServer

  alias Minga.Extension.ContributionCleanup

  @table __MODULE__

  @typedoc "Overlay shape hint for the frontend renderer."
  @type shape :: :cursor | :cursor_with_label | :label | :indicator

  @typedoc "Overlay style options."
  @type style :: %{optional(:fg) => non_neg_integer(), optional(:opacity) => 0..255}

  @typedoc "A registered overlay entry."
  @type entry :: %{
          extension: atom(),
          overlay_id: term(),
          buffer: pid(),
          position: {non_neg_integer(), non_neg_integer()},
          content: String.t(),
          style: style(),
          shape: shape()
        }

  @type table :: atom()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  @spec set(atom(), term(), pid(), keyword()) :: :ok
  @spec set(table(), atom(), term(), pid(), keyword()) :: :ok
  def set(extension_name, overlay_id, buffer_pid, opts),
    do: set(@table, extension_name, overlay_id, buffer_pid, opts)

  def set(table, extension_name, overlay_id, buffer_pid, opts)
      when is_atom(extension_name) and is_pid(buffer_pid) do
    entry = %{
      extension: extension_name,
      overlay_id: overlay_id,
      buffer: buffer_pid,
      position: Keyword.fetch!(opts, :position),
      content: Keyword.get(opts, :content, ""),
      style: Keyword.get(opts, :style, %{}),
      shape: Keyword.get(opts, :shape, :indicator)
    }

    :ets.insert(table, {{extension_name, overlay_id}, entry})
    :ok
  end

  @spec remove(atom(), term()) :: :ok
  @spec remove(table(), atom(), term()) :: :ok
  def remove(extension_name, overlay_id), do: remove(@table, extension_name, overlay_id)

  def remove(table, extension_name, overlay_id) when is_atom(extension_name) do
    :ets.delete(table, {extension_name, overlay_id})
    :ok
  end

  @spec remove_all(atom()) :: :ok
  @spec remove_all(table(), atom()) :: :ok
  def remove_all(extension_name), do: remove_all(@table, extension_name)

  def remove_all(table, extension_name) when is_atom(extension_name) do
    :ets.match_delete(table, {{extension_name, :_}, :_})
    :ok
  end

  @spec for_buffer(pid()) :: [entry()]
  @spec for_buffer(table(), pid()) :: [entry()]
  def for_buffer(buffer_pid), do: for_buffer(@table, buffer_pid)

  def for_buffer(table, buffer_pid) when is_pid(buffer_pid) do
    if table_ready?(table) do
      :ets.tab2list(table)
      |> Enum.filter(fn {_key, entry} -> entry.buffer == buffer_pid end)
      |> Enum.map(fn {_key, entry} -> entry end)
    else
      []
    end
  end

  @spec all() :: [entry()]
  @spec all(table()) :: [entry()]
  def all, do: all(@table)

  def all(table) do
    if table_ready?(table) do
      :ets.tab2list(table) |> Enum.map(fn {_key, entry} -> entry end)
    else
      []
    end
  end

  @spec empty?() :: boolean()
  @spec empty?(table()) :: boolean()
  def empty?, do: empty?(@table)
  def empty?(table), do: !table_ready?(table) or :ets.info(table, :size) == 0

  @spec unregister_source(ContributionCleanup.contribution_source()) :: :ok
  def unregister_source({:extension, name}) when is_atom(name), do: remove_all(name)
  def unregister_source(_source), do: :ok

  @impl true
  @spec init(keyword()) :: {:ok, table()}
  def init(opts) do
    table = Keyword.get(opts, :name, @table)
    create_owned_table(table)

    ContributionCleanup.register(:extension_overlays, fn source ->
      unregister_source(source)
    end)

    {:ok, table}
  end

  @spec table_ready?(table()) :: boolean()
  defp table_ready?(table), do: :ets.whereis(table) != :undefined

  @spec create_owned_table(table()) :: :ok
  defp create_owned_table(table) do
    :ets.new(table, [:named_table, :set, :public, read_concurrency: true])
    :ok
  end
end
