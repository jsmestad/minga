defmodule Minga.Extension.Panel do
  @moduledoc """
  Registry for extension-owned panels in the editor.

  Extensions register panels with structured content blocks (tables,
  key-value pairs, text, trees, progress bars). The Layer 2 emit
  pipeline reads this registry and encodes the content for the
  frontend, which renders it with native widgets.

  ## Usage from an extension

      Minga.Extension.Panel.set(:supervision_lens, "main", %{
        title: "Agent Sessions",
        position: :bottom,
        size: {:percent, 30},
        visible: true,
        content: [
          {:table, %{
            columns: ["Session", "Status", "Files"],
            rows: [["Claude", "thinking", "3"]],
            selected: 0
          }},
          {:separator},
          {:key_value, [{"Model", "claude-4"}, {"Cost", "$0.04"}]}
        ]
      })
  """

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
          | {:table, table_content()}
          | {:key_value, [{String.t(), String.t()}]}
          | {:separator}
          | {:progress, progress_content()}
          | {:tree, tree_content()}

  @typedoc "Table content with columns, rows, and optional selection."
  @type table_content :: map()

  @typedoc "Progress bar content."
  @type progress_content :: map()

  @typedoc "Tree node for hierarchical content."
  @type tree_node :: map()

  @typedoc "Tree content with nested nodes."
  @type tree_content :: map()

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

  @doc "Initializes the panel registry. Called during application startup."
  @spec init() :: :ok
  def init do
    unless :ets.whereis(@table) != :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

      ContributionCleanup.register(:extension_panels, fn source ->
        unregister_source(source)
      end)
    end

    :ok
  end

  @doc "Registers or updates a panel."
  @spec set(atom(), term(), map()) :: :ok
  def set(extension_name, panel_id, opts) when is_atom(extension_name) and is_map(opts) do
    entry = %{
      extension: extension_name,
      panel_id: panel_id,
      title: Map.get(opts, :title, ""),
      position: Map.get(opts, :position, :bottom),
      size: Map.get(opts, :size, {:percent, 30}),
      visible: Map.get(opts, :visible, true),
      content: Map.get(opts, :content, [])
    }

    :ets.insert(@table, {{extension_name, panel_id}, entry})
    :ok
  end

  @doc "Removes a specific panel."
  @spec remove(atom(), term()) :: :ok
  def remove(extension_name, panel_id) when is_atom(extension_name) do
    :ets.delete(@table, {extension_name, panel_id})
    :ok
  end

  @doc "Removes all panels for an extension."
  @spec remove_all(atom()) :: :ok
  def remove_all(extension_name) when is_atom(extension_name) do
    :ets.match_delete(@table, {{extension_name, :_}, :_})
    :ok
  end

  @doc "Returns all visible panels."
  @spec visible() :: [entry()]
  def visible do
    if :ets.whereis(@table) != :undefined do
      :ets.tab2list(@table)
      |> Enum.map(fn {_key, entry} -> entry end)
      |> Enum.filter(& &1.visible)
    else
      []
    end
  end

  @doc "Returns all registered panels."
  @spec all() :: [entry()]
  def all do
    if :ets.whereis(@table) != :undefined do
      :ets.tab2list(@table) |> Enum.map(fn {_key, entry} -> entry end)
    else
      []
    end
  end

  @doc "Returns true if no panels are registered."
  @spec empty?() :: boolean()
  def empty? do
    :ets.whereis(@table) == :undefined or :ets.info(@table, :size) == 0
  end

  @doc "Hides a panel without removing it."
  @spec hide(atom(), term()) :: :ok
  def hide(extension_name, panel_id) when is_atom(extension_name) do
    case :ets.lookup(@table, {extension_name, panel_id}) do
      [{{^extension_name, ^panel_id}, entry}] ->
        :ets.insert(@table, {{extension_name, panel_id}, %{entry | visible: false}})

      [] ->
        :ok
    end

    :ok
  end

  @doc "Shows a hidden panel."
  @spec show(atom(), term()) :: :ok
  def show(extension_name, panel_id) when is_atom(extension_name) do
    case :ets.lookup(@table, {extension_name, panel_id}) do
      [{{^extension_name, ^panel_id}, entry}] ->
        :ets.insert(@table, {{extension_name, panel_id}, %{entry | visible: true}})

      [] ->
        :ok
    end

    :ok
  end

  @doc "Removes all panels owned by a contribution source."
  @spec unregister_source(ContributionCleanup.contribution_source()) :: :ok
  def unregister_source({:extension, name}) when is_atom(name), do: remove_all(name)
  def unregister_source(_source), do: :ok
end
