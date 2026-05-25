defmodule MingaEditor.Extension.Sidebar do
  @moduledoc """
  Source-owned registry for extension sidebar contributions.

  Extensions register sidebar metadata once, then publish snapshots whenever their content changes. The editor render and layout paths read the cached registry state directly instead of invoking extension callbacks per frame.
  """

  use GenServer

  alias Minga.Extension.ContributionCleanup
  alias MingaEditor.Extension.Sidebar.Entry
  alias MingaEditor.Extension.Sidebar.Snapshot
  alias MingaEditor.State, as: EditorState

  @table __MODULE__
  @reserved_builtin_ids MapSet.new(["file_tree", "git_status", "observatory"])

  @typedoc "Registry table name."
  @type table :: atom()

  @typedoc "Contribution source that owns a sidebar."
  @type source :: ContributionCleanup.contribution_source()

  @typedoc "Sidebar placement."
  @type placement :: Entry.placement()

  @typedoc "Action handler invoked through the editor action pipeline."
  @type action_handler :: Entry.action_handler()

  @typedoc "Registered sidebar entry."
  @type entry :: Entry.t()

  @typedoc "Registration attributes."
  @type register_attrs :: %{
          required(:id) => String.t(),
          required(:display_name) => String.t(),
          optional(:description) => String.t(),
          optional(:placement) => placement(),
          optional(:priority) => integer(),
          optional(:preferred_width) => pos_integer(),
          optional(:visible?) => boolean(),
          optional(:focused?) => boolean(),
          optional(:semantic_kind) => String.t(),
          optional(:icon) => String.t(),
          optional(:input_handler) => module() | nil,
          optional(:action_handler) => action_handler(),
          optional(:snapshot) => Snapshot.t()
        }

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

  @doc "Registers or replaces a sidebar owned by `source`."
  @spec register(source(), register_attrs() | keyword()) :: :ok | {:error, term()}
  @spec register(table(), source(), register_attrs() | keyword()) :: :ok | {:error, term()}
  def register(source, attrs), do: register(@table, source, attrs)

  def register(table, source, attrs) when is_list(attrs) or is_map(attrs) do
    call_table(table, {:register, source, attrs})
  end

  @doc "Unregisters a sidebar when it is owned by the caller's source."
  @spec unregister(source(), String.t()) :: :ok | {:error, term()}
  @spec unregister(table(), source(), String.t()) :: :ok | {:error, term()}
  def unregister(source, id), do: unregister(@table, source, id)

  def unregister(table, source, id) when is_binary(id) do
    call_table(table, {:unregister, source, id})
  end

  @doc "Removes every sidebar owned by a source."
  @spec unregister_source(source()) :: :ok
  @spec unregister_source(table(), source()) :: :ok
  def unregister_source(source), do: unregister_source(@table, source)

  def unregister_source(table, source) do
    case call_table(table, {:unregister_source, source}) do
      :ok -> :ok
      {:error, :table_not_started} -> :ok
    end
  end

  @doc "Publishes a cached snapshot for a sidebar."
  @spec publish_snapshot(source(), String.t(), Snapshot.t() | keyword() | map()) ::
          :ok | {:error, term()}
  @spec publish_snapshot(table(), source(), String.t(), Snapshot.t() | keyword() | map()) ::
          :ok | {:error, term()}
  def publish_snapshot(source, id, snapshot), do: publish_snapshot(@table, source, id, snapshot)

  def publish_snapshot(table, source, id, snapshot) do
    call_table(table, {:publish_snapshot, source, id, snapshot})
  end

  @doc "Updates sidebar visibility."
  @spec set_visible(source(), String.t(), boolean()) :: :ok | {:error, term()}
  @spec set_visible(table(), source(), String.t(), boolean()) :: :ok | {:error, term()}
  def set_visible(source, id, visible?), do: set_visible(@table, source, id, visible?)

  def set_visible(table, source, id, visible?) when is_boolean(visible?) do
    call_table(table, {:set_visible, source, id, visible?})
  end

  @doc "Updates sidebar focus state."
  @spec set_focused(source(), String.t(), boolean()) :: :ok | {:error, term()}
  @spec set_focused(table(), source(), String.t(), boolean()) :: :ok | {:error, term()}
  def set_focused(source, id, focused?), do: set_focused(@table, source, id, focused?)

  def set_focused(table, source, id, focused?) when is_boolean(focused?) do
    call_table(table, {:set_focused, source, id, focused?})
  end

  @doc "Returns a sidebar by id."
  @spec get(String.t()) :: entry() | nil
  @spec get(table(), String.t()) :: entry() | nil
  def get(id), do: get(@table, id)
  def get(table, id), do: lookup(table, id)

  @doc "Returns all registered sidebars ordered by priority and id."
  @spec all() :: [entry()]
  @spec all(table()) :: [entry()]
  def all, do: all(@table)

  def all(table) do
    if table_ready?(table) do
      table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, entry} -> entry end)
      |> sort_entries()
    else
      []
    end
  end

  @doc "Returns visible registered sidebars ordered by priority and id."
  @spec visible() :: [entry()]
  @spec visible(table()) :: [entry()]
  def visible, do: visible(@table)
  def visible(table), do: all(table) |> Enum.filter(& &1.visible?)

  @doc "Returns the first visible left sidebar, if any."
  @spec active_left() :: entry() | nil
  @spec active_left(table()) :: entry() | nil
  def active_left, do: active_left(@table)

  def active_left(table) do
    table
    |> visible()
    |> Enum.filter(&(&1.placement == :left))
    |> Enum.sort_by(&{not &1.focused?, &1.priority, &1.id})
    |> List.first()
  end

  @doc "Dispatches a semantic action through the registered action handler."
  @spec dispatch_action(MingaEditor.State.t(), String.t(), String.t(), map()) ::
          MingaEditor.State.t()
  @spec dispatch_action(table(), MingaEditor.State.t(), String.t(), String.t(), map()) ::
          MingaEditor.State.t()
  def dispatch_action(state, sidebar_id, action, context \\ %{}) do
    dispatch_action(@table, state, sidebar_id, action, context)
  end

  def dispatch_action(table, state, sidebar_id, action, context) do
    case get(table, sidebar_id) do
      %{action_handler: nil} ->
        run_action_handler(nil, state, action, Map.put(context, :sidebar_id, sidebar_id))

      %{action_handler: handler} ->
        run_action_handler(handler, state, action, Map.put(context, :sidebar_id, sidebar_id))

      nil ->
        state
    end
  end

  @impl true
  @spec init(keyword()) :: {:ok, table()}
  def init(opts) do
    table = Keyword.get(opts, :name, @table)
    create_owned_table(table)

    ContributionCleanup.register(:editor_sidebars, fn source ->
      unregister_source(table, source)
    end)

    {:ok, table}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), table()) :: {:reply, term(), table()}
  def handle_call({:register, source, attrs}, _from, table) do
    {:reply, do_register(table, source, attrs), table}
  end

  def handle_call({:unregister, source, id}, _from, table) do
    {:reply, do_unregister(table, source, id), table}
  end

  def handle_call({:unregister_source, source}, _from, table) do
    {:reply, do_unregister_source(table, source), table}
  end

  def handle_call({:publish_snapshot, source, id, snapshot}, _from, table) do
    result =
      update_owned(table, source, id, fn entry ->
        Entry.publish_snapshot(entry, normalize_snapshot(snapshot))
      end)

    {:reply, result, table}
  end

  def handle_call({:set_visible, source, id, visible?}, _from, table) do
    {:reply, update_owned(table, source, id, &Entry.set_visible(&1, visible?)), table}
  end

  def handle_call({:set_focused, source, id, focused?}, _from, table) do
    {:reply, update_owned(table, source, id, &Entry.set_focused(&1, focused?)), table}
  end

  @spec do_register(table(), source(), register_attrs() | keyword()) :: :ok | {:error, term()}
  defp do_register(table, source, attrs) do
    with {:ok, entry} <- build_entry(source, attrs),
         :ok <- reject_reserved_builtin_id(source, entry.id),
         :ok <- reject_foreign_duplicate(table, source, entry.id) do
      :ets.insert(table, {entry.id, entry})
      notify_changed()
      :ok
    end
  end

  @spec do_unregister(table(), source(), String.t()) :: :ok | {:error, term()}
  defp do_unregister(table, source, id) do
    case lookup(table, id) do
      nil ->
        :ok

      %{source: ^source} ->
        :ets.delete(table, id)
        notify_changed()
        :ok

      %{source: other} ->
        {:error, {:owned_by, other}}
    end
  end

  @spec do_unregister_source(table(), source()) :: :ok
  defp do_unregister_source(table, source) do
    if remove_source_entries(table, source), do: notify_changed()
    :ok
  end

  @spec build_entry(source(), register_attrs() | keyword()) :: {:ok, entry()} | {:error, term()}
  defp build_entry(source, attrs) do
    attrs = Map.new(attrs)

    with {:ok, id} <- required_string(attrs, :id),
         {:ok, display_name} <- required_string(attrs, :display_name),
         {:ok, preferred_width} <- preferred_width(attrs),
         {:ok, placement} <- placement(attrs),
         {:ok, semantic_kind} <- semantic_kind(attrs, id) do
      {:ok,
       %Entry{
         source: source,
         id: id,
         display_name: display_name,
         description: Map.get(attrs, :description, ""),
         placement: placement,
         priority: Map.get(attrs, :priority, 100),
         preferred_width: preferred_width,
         visible?: Map.get(attrs, :visible?, false),
         focused?: Map.get(attrs, :focused?, false),
         semantic_kind: semantic_kind,
         icon: Map.get(attrs, :icon, "sidebar.left"),
         input_handler: Map.get(attrs, :input_handler),
         action_handler: Map.get(attrs, :action_handler),
         snapshot: normalize_snapshot(Map.get(attrs, :snapshot, Snapshot.new()))
       }}
    end
  end

  @spec required_string(map(), atom()) :: {:ok, String.t()} | {:error, term()}
  defp required_string(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid, key}}
    end
  end

  @spec preferred_width(map()) :: {:ok, pos_integer()} | {:error, term()}
  defp preferred_width(attrs) do
    case Map.get(attrs, :preferred_width, 30) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid, :preferred_width}}
    end
  end

  @spec placement(map()) :: {:ok, placement()} | {:error, term()}
  defp placement(attrs) do
    case Map.get(attrs, :placement, :left) do
      :left -> {:ok, :left}
      other -> {:error, {:unsupported_placement, other}}
    end
  end

  @spec semantic_kind(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp semantic_kind(attrs, id) do
    case Map.get(attrs, :semantic_kind, "generic") do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> {:ok, id}
      _ -> {:error, {:invalid, :semantic_kind}}
    end
  end

  @spec normalize_snapshot(Snapshot.t() | keyword() | map()) :: Snapshot.t()
  defp normalize_snapshot(%Snapshot{} = snapshot), do: snapshot
  defp normalize_snapshot(snapshot), do: Snapshot.new(snapshot)

  @spec remove_source_entries(table(), source()) :: boolean()
  defp remove_source_entries(table, source) do
    table
    |> :ets.tab2list()
    |> Enum.reduce(false, fn {id, entry}, removed? ->
      remove_source_entry(table, source, id, entry, removed?)
    end)
  end

  @spec remove_source_entry(table(), source(), String.t(), Entry.t(), boolean()) :: boolean()
  defp remove_source_entry(table, source, id, %Entry{source: source}, _removed?) do
    :ets.delete(table, id)
    true
  end

  defp remove_source_entry(_table, _source, _id, %Entry{}, removed?), do: removed?

  @spec reject_reserved_builtin_id(source(), String.t()) :: :ok | {:error, term()}
  defp reject_reserved_builtin_id(:builtin, _id), do: :ok

  defp reject_reserved_builtin_id(_source, id) do
    if MapSet.member?(@reserved_builtin_ids, id) do
      {:error, {:reserved_sidebar_id, id}}
    else
      :ok
    end
  end

  @spec reject_foreign_duplicate(table(), source(), String.t()) :: :ok | {:error, term()}
  defp reject_foreign_duplicate(table, source, id) do
    case lookup(table, id) do
      nil -> :ok
      %{source: ^source} -> :ok
      %{source: other} -> {:error, {:duplicate_sidebar_id, id, other}}
    end
  end

  @spec update_owned(table(), source(), String.t(), (entry() -> entry())) ::
          :ok | {:error, term()}
  defp update_owned(table, source, id, fun) do
    case lookup(table, id) do
      nil ->
        {:error, :not_found}

      %{source: ^source} = entry ->
        :ets.insert(table, {id, fun.(entry)})
        notify_changed()
        :ok

      %{source: other} ->
        {:error, {:owned_by, other}}
    end
  end

  @spec lookup(table(), String.t()) :: entry() | nil
  defp lookup(table, id) do
    if table_ready?(table) do
      case :ets.lookup(table, id) do
        [{^id, entry}] -> entry
        [] -> nil
      end
    end
  end

  @spec sort_entries([entry()]) :: [entry()]
  defp sort_entries(entries), do: Enum.sort_by(entries, &{&1.priority, &1.id})

  @spec notify_changed() :: :ok
  defp notify_changed do
    if Process.whereis(MingaEditor), do: MingaEditor.render()
    :ok
  end

  @spec run_action_handler(action_handler(), MingaEditor.State.t(), String.t(), map()) ::
          MingaEditor.State.t()
  defp run_action_handler(nil, state, action, context) do
    sidebar_id = Map.get(context, :sidebar_id, "unknown")

    Minga.Log.warning(
      :editor,
      "Ignored sidebar action #{inspect(action)} for #{inspect(sidebar_id)}: no action handler"
    )

    EditorState.set_status(state, "Sidebar #{sidebar_id} has no action handler")
  end

  defp run_action_handler(fun, state, action, context) when is_function(fun, 3),
    do: fun.(state, action, context)

  defp run_action_handler({module, function}, state, action, context),
    do: apply(module, function, [state, action, context])

  defp run_action_handler({module, function, extra}, state, action, context),
    do: apply(module, function, [state, action, context | extra])

  @spec call_table(table(), term()) :: term()
  defp call_table(table, message) do
    case Process.whereis(table) do
      nil -> {:error, :table_not_started}
      _pid -> GenServer.call(table, message)
    end
  end

  @spec table_ready?(table()) :: boolean()
  defp table_ready?(table), do: :ets.whereis(table) != :undefined

  @spec create_owned_table(table()) :: :ok
  defp create_owned_table(table) do
    :ets.new(table, [:named_table, :set, :protected, read_concurrency: true])
    :ok
  end
end
