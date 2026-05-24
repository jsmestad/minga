defmodule Minga.Extension.Panel do
  @moduledoc """
  ETS-backed registry for extension-owned panels in the editor.

  Extensions register panels with structured content blocks (tables,
  key-value pairs, text, trees, progress bars). The Layer 2 emit
  pipeline reads this registry and encodes the content for the
  frontend, which renders it with native widgets.
  """

  use GenServer

  alias Minga.Extension.ContributionCleanup

  @table __MODULE__

  @typedoc "Panel position in the editor layout."
  @type position :: :bottom | :right | :float

  @typedoc "Panel size specification."
  @type size :: {:percent, 1..100} | {:lines, pos_integer()}

  @typedoc "A content block in a panel."
  @type content_block ::
          {:text, String.t()}
          | {:styled_text, [{String.t(), non_neg_integer(), keyword()}]}
          | {:table, map()}
          | {:key_value, [{String.t(), String.t()}]}
          | {:separator}
          | {:progress, map()}
          | {:tree, map()}

  @typedoc "A registered panel entry."
  @type entry :: %{
          extension: atom(),
          panel_id: term(),
          title: String.t(),
          position: position(),
          size: size(),
          visible: boolean(),
          content: [content_block()]
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

  @spec set(atom(), term(), map()) :: :ok
  @spec set(table(), atom(), term(), map()) :: :ok
  def set(extension_name, panel_id, opts), do: set(@table, extension_name, panel_id, opts)

  def set(table, extension_name, panel_id, opts)
      when is_atom(extension_name) and is_map(opts) do
    entry = %{
      extension: extension_name,
      panel_id: panel_id,
      title: Map.get(opts, :title, ""),
      position: Map.get(opts, :position, :bottom),
      size: Map.get(opts, :size, {:percent, 30}),
      visible: Map.get(opts, :visible, true),
      content: Map.get(opts, :content, [])
    }

    :ets.insert(table, {{extension_name, panel_id}, entry})
    :ok
  end

  @spec remove(atom(), term()) :: :ok
  @spec remove(table(), atom(), term()) :: :ok
  def remove(extension_name, panel_id), do: remove(@table, extension_name, panel_id)

  def remove(table, extension_name, panel_id) when is_atom(extension_name) do
    :ets.delete(table, {extension_name, panel_id})
    :ok
  end

  @spec remove_all(atom()) :: :ok
  @spec remove_all(table(), atom()) :: :ok
  def remove_all(extension_name), do: remove_all(@table, extension_name)

  def remove_all(table, extension_name) when is_atom(extension_name) do
    :ets.match_delete(table, {{extension_name, :_}, :_})
    :ok
  end

  @spec visible() :: [entry()]
  @spec visible(table()) :: [entry()]
  def visible, do: visible(@table)

  def visible(table) do
    if table_ready?(table) do
      :ets.tab2list(table)
      |> Enum.map(fn {_key, entry} -> entry end)
      |> Enum.filter(& &1.visible)
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

  @spec hide(atom(), term()) :: :ok
  def hide(extension_name, panel_id) when is_atom(extension_name) do
    update_visibility(@table, extension_name, panel_id, false)
  end

  @spec show(atom(), term()) :: :ok
  def show(extension_name, panel_id) when is_atom(extension_name) do
    update_visibility(@table, extension_name, panel_id, true)
  end

  @spec unregister_source(ContributionCleanup.contribution_source()) :: :ok
  def unregister_source({:extension, name}) when is_atom(name), do: remove_all(name)
  def unregister_source(_source), do: :ok

  @impl true
  @spec init(keyword()) :: {:ok, table()}
  def init(opts) do
    table = Keyword.get(opts, :name, @table)
    create_owned_table(table)

    ContributionCleanup.register(:extension_panels, fn source ->
      unregister_source(source)
    end)

    {:ok, table}
  end

  @spec update_visibility(table(), atom(), term(), boolean()) :: :ok
  defp update_visibility(table, extension_name, panel_id, visible) do
    case :ets.lookup(table, {extension_name, panel_id}) do
      [{key, entry}] -> :ets.insert(table, {key, %{entry | visible: visible}})
      [] -> :ok
    end

    :ok
  end

  @spec table_ready?(table()) :: boolean()
  defp table_ready?(table), do: :ets.whereis(table) != :undefined

  @spec create_owned_table(table()) :: :ok
  defp create_owned_table(table) do
    :ets.new(table, [:named_table, :set, :public, read_concurrency: true])
    :ok
  end
end
