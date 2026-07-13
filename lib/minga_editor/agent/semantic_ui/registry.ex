defmodule MingaEditor.Agent.SemanticUI.Registry do
  @moduledoc """
  Source-owned registry for semantic agent UI contributions.

  Extensions and bundles register cached `Minga.RenderModel.UI.*` values here. Render builders and input handlers read the ETS table directly, so frame and keystroke hot paths never invoke extension render callbacks.
  """

  use GenServer

  alias Minga.Extension.ContributionCleanup
  alias Minga.Extension.Manifest
  alias Minga.RenderModel.UI.Action
  alias Minga.RenderModel.UI.AgentChat
  alias Minga.RenderModel.UI.ExtensionPanel
  alias MingaEditor.Agent.SemanticUI.Entry
  alias MingaEditor.Commands
  alias MingaEditor.State, as: EditorState

  @table __MODULE__
  @default_notify MingaEditor

  @typedoc "Registry table name."
  @type table :: atom()

  @typedoc "Source that owns semantic UI entries."
  @type source :: ContributionCleanup.contribution_source()

  @typedoc "Semantic surface name."
  @type surface :: Entry.surface()

  @typedoc "Existing render-model payload stored by an entry."
  @type payload :: Entry.payload()

  @typedoc "Registration attributes."
  @type register_attrs :: %{
          required(:id) => String.t(),
          required(:surface) => surface(),
          required(:payload) => payload(),
          optional(:target) => term(),
          optional(:priority) => integer(),
          optional(:actions) => [Action.t() | map() | keyword()]
        }

  @type state :: table()

  @doc "Starts the semantic UI registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    id = Keyword.get(opts, :name, __MODULE__)
    %{id: id, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  @doc "Returns the default production registry table."
  @spec default_table() :: table()
  def default_table, do: @table

  @doc "Returns the semantic UI registry table for a state-like value."
  @spec table_for(map() | nil) :: table()
  def table_for(%{agent_semantic_ui_registry: table}) when is_atom(table), do: table
  def table_for(_state), do: @table

  @doc "Registers or replaces a source-owned semantic UI entry."
  @spec register(source(), register_attrs() | Entry.t() | keyword()) :: :ok | {:error, term()}
  @spec register(table(), source(), register_attrs() | Entry.t() | keyword()) ::
          :ok | {:error, term()}
  def register(source, attrs), do: register(@table, source, attrs)

  def register(table, source, attrs) do
    call_table(table, {:register, source, attrs})
  end

  @doc "Registers a source-owned batch, replacing all prior entries owned by the same source."
  @spec register_many(source(), [register_attrs() | Entry.t() | keyword()]) ::
          :ok | {:error, term()}
  @spec register_many(table(), source(), [register_attrs() | Entry.t() | keyword()]) ::
          :ok | {:error, term()}
  def register_many(source, entries), do: register_many(@table, source, entries)

  def register_many(table, source, entries) when is_list(entries) do
    call_table(table, {:register_many, source, entries})
  end

  @doc "Publishes a new cached render-model payload for an existing entry."
  @spec publish(source(), String.t(), payload(), [Action.t() | map() | keyword()] | nil) ::
          :ok | {:error, term()}
  @spec publish(table(), source(), String.t(), payload(), [Action.t() | map() | keyword()] | nil) ::
          :ok | {:error, term()}
  def publish(source, id, payload, actions \\ nil),
    do: publish(@table, source, id, payload, actions)

  def publish(table, source, id, payload, actions) when is_binary(id) do
    call_table(table, {:publish, source, id, payload, actions})
  end

  @doc "Unregisters an entry when it is owned by the caller's source."
  @spec unregister(source(), String.t()) :: :ok | {:error, term()}
  @spec unregister(table(), source(), String.t()) :: :ok | {:error, term()}
  def unregister(source, id), do: unregister(@table, source, id)

  def unregister(table, source, id) when is_binary(id) do
    call_table(table, {:unregister, source, id})
  end

  @doc "Removes every semantic UI entry owned by a source."
  @spec unregister_source(source()) :: :ok
  @spec unregister_source(table(), source()) :: :ok
  def unregister_source(source), do: unregister_source(@table, source)

  def unregister_source(table, source) do
    case call_table(table, {:unregister_source, source}) do
      :ok -> :ok
      {:error, :table_not_started} -> :ok
    end
  end

  @doc "Returns an entry by id."
  @spec get(String.t()) :: Entry.t() | nil
  @spec get(table(), String.t()) :: Entry.t() | nil
  def get(id), do: get(@table, id)
  def get(table, id), do: lookup(table, id)

  @doc "Returns all entries ordered by priority and id."
  @spec all() :: [Entry.t()]
  @spec all(table()) :: [Entry.t()]
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

  @doc "Returns all entries for a semantic surface ordered by priority and id."
  @spec entries(surface()) :: [Entry.t()]
  @spec entries(table(), surface()) :: [Entry.t()]
  def entries(surface), do: entries(@table, surface)

  def entries(table, surface) do
    table
    |> all()
    |> Enum.filter(&(&1.surface == surface))
  end

  @doc "Returns cached transcript enrichment bodies."
  @spec transcript_enrichments() :: [{pos_integer(), AgentChat.message_body()}]
  @spec transcript_enrichments(table()) :: [{pos_integer(), AgentChat.message_body()}]
  def transcript_enrichments, do: transcript_enrichments(@table)

  def transcript_enrichments(table) do
    table
    |> entries(:transcript_enrichment)
    |> Enum.map(&{stable_message_id(&1), &1.payload})
  end

  @doc "Returns cached extension-panel panels contributed to agent UI."
  @spec panels() :: [ExtensionPanel.Panel.t()]
  @spec panels(table()) :: [ExtensionPanel.Panel.t()]
  def panels, do: panels(@table)

  def panels(table) do
    panel_entries = entries(table, :panel) |> Enum.map(& &1.payload)
    dashboard_entries = entries(table, :dashboard_section) |> Enum.map(&dashboard_panel/1)
    panel_entries ++ dashboard_entries
  end

  @doc "Dispatches a semantic action through the editor command pipeline."
  @spec dispatch_action(EditorState.t(), String.t(), String.t(), map()) :: EditorState.t()
  @spec dispatch_action(table(), EditorState.t(), String.t(), String.t(), map()) ::
          EditorState.t()
  def dispatch_action(state, entry_id, action_id, context \\ %{}) do
    dispatch_action(@table, state, entry_id, action_id, context)
  end

  def dispatch_action(table, state, entry_id, action_id, context) do
    case action_for(table, entry_id, action_id) do
      {:ok, entry, %Action{enabled?: true} = action} ->
        dispatch_editor_action(
          state,
          action_context(entry, action, context),
          action.editor_action
        )

      {:ok, _entry, %Action{enabled?: false}} ->
        MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "Agent UI action unavailable")

      :error ->
        state
    end
  end

  @doc "Dispatches a semantic extension-panel action by frontend source label."
  @spec dispatch_panel_action(EditorState.t(), String.t(), atom() | String.t(), map()) ::
          {:ok, EditorState.t()} | :error
  @spec dispatch_panel_action(table(), EditorState.t(), String.t(), atom() | String.t(), map()) ::
          {:ok, EditorState.t()} | :error
  def dispatch_panel_action(state, ext_name, action_name, context \\ %{}) do
    dispatch_panel_action(table_for(state), state, ext_name, action_name, context)
  end

  def dispatch_panel_action(table, state, ext_name, action_name, context)
      when is_binary(ext_name) do
    action_id = semantic_action_id(action_name)

    case panel_action_entry(table, ext_name, action_id) do
      %Entry{id: entry_id} -> {:ok, dispatch_action(table, state, entry_id, action_id, context)}
      nil -> :error
    end
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    table = Keyword.get(opts, :name, @table)
    notify = Keyword.get(opts, :notify, if(table == @table, do: @default_notify, else: false))
    create_owned_table(table)
    :persistent_term.put({__MODULE__, table, :notify}, notify)

    if table == @table do
      Minga.Events.subscribe(:extension_agent_contributions_started)

      ContributionCleanup.register(:agent_semantic_ui_registry, fn source ->
        unregister_source(table, source)
      end)

      seed_bundled_sources(table)
      seed_from_running_extensions(table)
    end

    {:ok, table}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call({:register, source, attrs}, _from, table) do
    {:reply, do_register(table, source, attrs), table}
  end

  def handle_call({:register_many, source, entries}, _from, table) do
    {:reply, do_register_many(table, source, entries), table}
  end

  def handle_call({:publish, source, id, payload, actions}, _from, table) do
    {:reply, update_owned(table, source, id, &Entry.publish(&1, payload, actions)), table}
  end

  def handle_call({:unregister, source, id}, _from, table) do
    {:reply, do_unregister(table, source, id), table}
  end

  def handle_call({:unregister_source, source}, _from, table) do
    {:reply, do_unregister_source(table, source), table}
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info(
        {:minga_event, :extension_agent_contributions_started,
         %{source: source, manifest: %Manifest{} = manifest}},
        table
      ) do
    register_manifest_entries(table, source, manifest.agent_ui_metadata)
    {:noreply, table}
  end

  def handle_info(_msg, table), do: {:noreply, table}

  @spec seed_bundled_sources(table()) :: :ok
  defp seed_bundled_sources(table) do
    source = MingaEditor.Agent.SemanticUI.BundledStatusNote.source()

    case do_register_many(
           table,
           source,
           MingaEditor.Agent.SemanticUI.BundledStatusNote.entries()
         ) do
      :ok -> :ok
      {:error, reason} -> log_manifest_entry_error(source, reason)
    end
  end

  @spec seed_from_running_extensions(table()) :: :ok
  defp seed_from_running_extensions(table) do
    if Process.whereis(Minga.Extension.Registry) do
      Minga.Extension.Registry.all()
      |> Enum.filter(fn {_name, entry} -> entry.status == :running and entry.manifest != nil end)
      |> Enum.each(fn {name, entry} ->
        register_manifest_entries(table, {:extension, name}, entry.manifest.agent_ui_metadata)
      end)
    end

    :ok
  rescue
    exception ->
      log_seed_error(table, {:exception, exception})
  catch
    :exit, reason -> log_seed_error(table, {:exit, reason})
  end

  @spec log_seed_error(table(), term()) :: :ok
  defp log_seed_error(table, reason) do
    Minga.Log.warning(
      :agent,
      "Semantic agent UI registry #{inspect(table)} could not seed running extension contributions: #{inspect(reason)}"
    )
  end

  @spec register_manifest_entries(table(), source(), [term()]) :: :ok
  defp register_manifest_entries(_table, _source, []), do: :ok

  defp register_manifest_entries(table, source, entries) when is_list(entries) do
    case do_register_many(table, source, entries) do
      :ok -> :ok
      {:error, reason} -> log_manifest_entry_error(source, reason)
    end
  end

  defp register_manifest_entries(_table, source, _entries),
    do: log_manifest_entry_error(source, :invalid_agent_ui_metadata)

  @spec log_manifest_entry_error(source(), term()) :: :ok
  defp log_manifest_entry_error(source, reason) do
    Minga.Log.warning(
      :agent,
      "Ignoring semantic agent UI contributions for #{inspect(source)}: #{inspect(reason)}"
    )
  end

  @spec do_register(table(), source(), register_attrs() | Entry.t() | keyword()) ::
          :ok | {:error, term()}
  defp do_register(table, source, attrs) do
    with {:ok, entry} <- Entry.new(source, attrs),
         :ok <- reject_foreign_duplicate(table, source, entry.id) do
      :ets.insert(table, {entry.id, entry})
      notify_changed(table)
      :ok
    end
  end

  @spec do_register_many(table(), source(), [register_attrs() | Entry.t() | keyword()]) ::
          :ok | {:error, term()}
  defp do_register_many(table, source, attrs_list) do
    case normalize_entries(source, attrs_list, []) do
      {:ok, entries} -> insert_many(table, source, entries)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec do_unregister(table(), source(), String.t()) :: :ok | {:error, term()}
  defp do_unregister(table, source, id) do
    case lookup(table, id) do
      nil -> :ok
      %{source: ^source} -> delete_entry(table, id)
      %{source: other} -> {:error, {:owned_by, other}}
    end
  end

  @spec do_unregister_source(table(), source()) :: :ok
  defp do_unregister_source(table, source) do
    if remove_source_entries(table, source), do: notify_changed(table)
    :ok
  end

  @spec normalize_entries(source(), [term()], [Entry.t()]) ::
          {:ok, [Entry.t()]} | {:error, term()}
  defp normalize_entries(_source, [], acc), do: {:ok, Enum.reverse(acc)}

  defp normalize_entries(source, [attrs | rest], acc) do
    case Entry.new(source, attrs) do
      {:ok, entry} -> normalize_entries(source, rest, [entry | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  @spec insert_many(table(), source(), [Entry.t()]) :: :ok | {:error, term()}
  defp insert_many(table, source, entries) do
    with :ok <- reject_batch_duplicate_ids(entries) do
      case foreign_duplicate(table, source, entries) do
        nil -> replace_source_entries(table, source, entries)
        {id, other} -> {:error, {:duplicate_agent_ui_id, id, other}}
      end
    end
  end

  @spec reject_batch_duplicate_ids([Entry.t()]) :: :ok | {:error, term()}
  defp reject_batch_duplicate_ids(entries) do
    entries
    |> Enum.map(& &1.id)
    |> Enum.frequencies()
    |> Enum.find(fn {_id, count} -> count > 1 end)
    |> case do
      nil -> :ok
      {id, _count} -> {:error, {:duplicate_agent_ui_id, id, :same_batch}}
    end
  end

  @spec replace_source_entries(table(), source(), [Entry.t()]) :: :ok
  defp replace_source_entries(table, source, entries) do
    remove_source_entries(table, source)
    Enum.each(entries, &:ets.insert(table, {&1.id, &1}))
    notify_changed(table)
    :ok
  end

  @spec foreign_duplicate(table(), source(), [Entry.t()]) :: {String.t(), source()} | nil
  defp foreign_duplicate(table, source, entries) do
    Enum.find_value(entries, fn entry ->
      case lookup(table, entry.id) do
        nil -> nil
        %{source: ^source} -> nil
        %{source: other} -> {entry.id, other}
      end
    end)
  end

  @spec reject_foreign_duplicate(table(), source(), String.t()) :: :ok | {:error, term()}
  defp reject_foreign_duplicate(table, source, id) do
    case lookup(table, id) do
      nil -> :ok
      %{source: ^source} -> :ok
      %{source: other} -> {:error, {:duplicate_agent_ui_id, id, other}}
    end
  end

  @spec update_owned(table(), source(), String.t(), (Entry.t() ->
                                                       {:ok, Entry.t()} | {:error, term()})) ::
          :ok | {:error, term()}
  defp update_owned(table, source, id, fun) do
    case lookup(table, id) do
      nil ->
        {:error, :not_found}

      %{source: ^source} = entry ->
        case fun.(entry) do
          {:ok, updated} ->
            :ets.insert(table, {id, updated})
            notify_changed(table)
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      %{source: other} ->
        {:error, {:owned_by, other}}
    end
  end

  @spec action_for(table(), String.t(), String.t()) :: {:ok, Entry.t(), Action.t()} | :error
  defp action_for(table, entry_id, action_id) do
    case lookup(table, entry_id) do
      %Entry{} = entry -> find_action(entry, action_id)
      nil -> :error
    end
  end

  @spec find_action(Entry.t(), String.t()) :: {:ok, Entry.t(), Action.t()} | :error
  defp find_action(%Entry{actions: actions} = entry, action_id) do
    case Enum.find(actions, &(&1.id == action_id)) do
      %Action{} = action -> {:ok, entry, action}
      nil -> :error
    end
  end

  @spec panel_action_entry(table(), String.t(), String.t()) :: Entry.t() | nil
  defp panel_action_entry(table, ext_name, action_id) do
    table
    |> all()
    |> Enum.find(&semantic_panel_action_entry?(&1, ext_name, action_id))
  end

  @spec semantic_panel_action_entry?(Entry.t(), String.t(), String.t()) :: boolean()
  defp semantic_panel_action_entry?(
         %Entry{surface: surface, actions: actions} = entry,
         ext_name,
         action_id
       )
       when surface in [:dashboard_section, :panel] do
    semantic_panel_source?(entry, ext_name) and Enum.any?(actions, &(&1.id == action_id))
  end

  defp semantic_panel_action_entry?(%Entry{}, _ext_name, _action_id), do: false

  @spec semantic_panel_source?(Entry.t(), String.t()) :: boolean()
  defp semantic_panel_source?(
         %Entry{source: source, payload: %ExtensionPanel.Panel{extension: extension}},
         ext_name
       ) do
    extension == ext_name or source_label(source) == ext_name
  end

  defp semantic_panel_source?(%Entry{source: source}, ext_name),
    do: source_label(source) == ext_name

  @spec semantic_action_id(atom() | String.t()) :: String.t()
  defp semantic_action_id(action_name) when is_atom(action_name), do: Atom.to_string(action_name)
  defp semantic_action_id(action_name) when is_binary(action_name), do: action_name

  @spec dispatch_editor_action(EditorState.t(), map(), Action.editor_action()) :: EditorState.t()
  defp dispatch_editor_action(state, _context, nil), do: state

  defp dispatch_editor_action(state, _context, editor_action) do
    editor_action
    |> then(&Commands.execute(state, &1))
    |> normalize_command_result()
  end

  @spec normalize_command_result(EditorState.t() | {EditorState.t(), term()}) :: EditorState.t()
  defp normalize_command_result({state, _action}), do: state
  defp normalize_command_result(state), do: state

  @spec action_context(Entry.t(), Action.t(), map()) :: map()
  defp action_context(entry, action, context) do
    action.payload
    |> Map.merge(context)
    |> Map.put(:entry_id, entry.id)
    |> Map.put(:action_id, action.id)
    |> Map.put(:surface, entry.surface)
    |> Map.put(:target, entry.target)
  end

  @spec dashboard_panel(Entry.t()) :: ExtensionPanel.Panel.t()
  defp dashboard_panel(%Entry{id: id, source: source, payload: content}) do
    %ExtensionPanel.Panel{
      extension: source_label(source),
      panel_id: "agent-dashboard-#{id}",
      title: "Agent Dashboard",
      position: :right,
      size: {:percent, 30},
      visible?: true,
      content: content
    }
  end

  @spec source_label(source()) :: String.t()
  defp source_label(:builtin), do: "builtin"
  defp source_label(:config), do: "config"
  defp source_label({:bundle, name}), do: "bundle:#{name}"
  defp source_label({:extension, name}), do: "extension:#{name}"

  @spec stable_message_id(Entry.t()) :: pos_integer()
  defp stable_message_id(%Entry{id: id}), do: :erlang.phash2({__MODULE__, id}, 0xFFFF_FFFE) + 1

  @spec delete_entry(table(), String.t()) :: :ok
  defp delete_entry(table, id) do
    :ets.delete(table, id)
    notify_changed(table)
    :ok
  end

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

  @spec lookup(table(), String.t()) :: Entry.t() | nil
  defp lookup(table, id) do
    if table_ready?(table) do
      case :ets.lookup(table, id) do
        [{^id, entry}] -> entry
        [] -> nil
      end
    end
  end

  @spec sort_entries([Entry.t()]) :: [Entry.t()]
  defp sort_entries(entries), do: Enum.sort_by(entries, &{&1.priority, &1.id})

  @spec notify_changed(table()) :: :ok
  defp notify_changed(table) do
    case table_notify_target(table) do
      false ->
        :ok

      MingaEditor ->
        if Process.whereis(MingaEditor), do: MingaEditor.render()
        :ok

      pid when is_pid(pid) ->
        send(pid, {:agent_semantic_ui_changed, table})
        :ok

      name when is_atom(name) ->
        if Process.whereis(name), do: GenServer.cast(name, :render)
        :ok
    end
  end

  @spec table_notify_target(table()) :: false | pid() | atom()
  defp table_notify_target(table) do
    case :persistent_term.get({__MODULE__, table, :notify}, :missing) do
      :missing -> @default_notify
      notify -> notify
    end
  end

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
