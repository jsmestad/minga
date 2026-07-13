defmodule MingaEditor.Shell.Runtime do
  @moduledoc """
  Immutable owner of the editor's active shell runtime value.

  A runtime contains one resolved registry entry, the state produced by that shell, and stashed states tied to exact registry identities. Registry lookup and every effectful policy decision stay outside this module. Callers resolve entries and initialize replacement states before invoking a transition.
  """

  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Identity
  alias MingaEditor.Shell.StateStash
  alias MingaEditor.State.TabBar

  @type shell_state :: MingaEditor.Shell.shell_state()
  @type stash :: %{atom() => StateStash.t()}
  @type persistence_change :: {Entry.t(), shell_state(), shell_state()}

  @enforce_keys [:entry, :state]
  defstruct [:entry, :state, stash: %{}]

  @type t :: %__MODULE__{entry: Entry.t(), state: shell_state(), stash: stash()}

  @doc "Returns the deterministic built-in entry used by raw Editor state construction."
  @spec default_entry() :: Entry.t()
  def default_entry do
    %Entry{
      id: :traditional,
      source: :builtin,
      module: MingaEditor.Shell.Traditional,
      display_name: "Traditional",
      description: "Traditional editor shell",
      capabilities: [:gui, :tui],
      default?: true,
      generation: 1
    }
  end

  @doc "Builds a runtime from an already-resolved entry and initialized shell state."
  @spec new(Entry.t(), shell_state()) :: t()
  def new(%Entry{} = entry, state), do: %__MODULE__{entry: entry, state: state}

  @doc "Returns the resolved active entry."
  @spec entry(t()) :: Entry.t()
  def entry(%__MODULE__{entry: entry}), do: entry

  @doc "Returns the active shell id."
  @spec id(t()) :: atom()
  def id(%__MODULE__{entry: %Entry{id: id}}), do: id

  @doc "Returns the active shell contract module."
  @spec module(t()) :: module()
  def module(%__MODULE__{entry: %Entry{module: module}}), do: module

  @doc "Returns the active shell state."
  @spec state(t()) :: shell_state()
  def state(%__MODULE__{state: state}), do: state

  @doc "Returns the identity-keyed shell-state stash."
  @spec stash(t()) :: stash()
  def stash(%__MODULE__{stash: stash}), do: stash

  @doc "Returns the exact identity of the active resolved entry."
  @spec identity(t()) :: Identity.t()
  def identity(%__MODULE__{entry: entry}), do: Identity.new(entry)

  @doc "Returns true when an asynchronous identity belongs to the active entry."
  @spec matches_identity?(t(), Identity.t()) :: boolean()
  def matches_identity?(%__MODULE__{entry: entry}, %Identity{} = identity),
    do: Identity.matches?(identity, entry)

  @doc "Returns true when a resolved entry is exactly the active registration."
  @spec active_entry?(t(), Entry.t()) :: boolean()
  def active_entry?(%__MODULE__{entry: active}, %Entry{} = entry), do: same_entry?(active, entry)

  @doc "Returns whether an exact-identity stashed value can restore the resolved entry."
  @spec restorable?(t(), Entry.t()) :: boolean()
  def restorable?(%__MODULE__{} = runtime, %Entry{} = entry) do
    case Map.get(runtime.stash, entry.id) do
      %StateStash{} = stashed -> StateStash.matches?(stashed, entry)
      nil -> false
    end
  end

  @doc "Activates a resolved entry, stashing the outgoing state and restoring only an exact identity match."
  @spec activate(t(), Entry.t(), shell_state()) :: t()
  def activate(%__MODULE__{} = runtime, %Entry{} = target, initialized_state) do
    if same_entry?(runtime.entry, target) do
      runtime
    else
      stash =
        Map.put(runtime.stash, runtime.entry.id, StateStash.new(runtime.entry, runtime.state))

      {target_state, stash} = restore_target(stash, target, initialized_state)
      %__MODULE__{entry: target, state: target_state, stash: stash}
    end
  end

  @doc "Accepts the currently resolved active entry or resets state when its registry identity changed."
  @spec validate_registration(t(), Entry.t(), shell_state()) :: {t(), :current | :reset}
  def validate_registration(%__MODULE__{} = runtime, %Entry{} = resolved, initialized_state) do
    if same_entry?(runtime.entry, resolved) do
      {runtime, :current}
    else
      {%__MODULE__{
         runtime
         | entry: resolved,
           state: initialized_state,
           stash: Map.delete(runtime.stash, resolved.id)
       }, :reset}
    end
  end

  @doc "Falls back from a removed active registration without stashing its now-unresolvable value."
  @spec fallback_from_removed(t(), Entry.t(), shell_state()) :: t()
  def fallback_from_removed(%__MODULE__{} = runtime, %Entry{} = default_entry, initialized_state) do
    {target_state, stash} = restore_target(runtime.stash, default_entry, initialized_state)
    %__MODULE__{entry: default_entry, state: target_state, stash: stash}
  end

  @doc "Updates Traditional presentation state and leaves extension runtimes untouched."
  @spec update_traditional_state(t(), (shell_state() -> shell_state())) :: t()
  def update_traditional_state(
        %__MODULE__{entry: %Entry{module: MingaEditor.Shell.Traditional}} = runtime,
        fun
      )
      when is_function(fun, 1) do
    %__MODULE__{runtime | state: fun.(runtime.state)}
  end

  def update_traditional_state(%__MODULE__{} = runtime, fun) when is_function(fun, 1), do: runtime

  @doc "Installs shell state returned by a render for the exact active identity."
  @spec accept_rendered_state(t(), atom(), Identity.t(), shell_state()) :: t()
  def accept_rendered_state(
        %__MODULE__{} = runtime,
        shell_id,
        %Identity{} = identity,
        rendered_state
      ) do
    if runtime.entry.id == shell_id and Identity.matches?(identity, runtime.entry),
      do: %__MODULE__{runtime | state: rendered_state},
      else: runtime
  end

  @doc "Installs state returned by persistence for the exact active or stashed registration."
  @spec accept_persisted_state(t(), Entry.t(), shell_state()) :: t()
  def accept_persisted_state(%__MODULE__{} = runtime, %Entry{} = entry, persisted_state) do
    if same_entry?(runtime.entry, entry) do
      %__MODULE__{runtime | state: persisted_state}
    else
      accept_stashed_persisted_state(runtime, entry, persisted_state)
    end
  end

  @doc "Routes a shell event through the active entry's contract."
  @spec route_event(t(), MingaEditor.Shell.workspace(), term()) ::
          {t(), MingaEditor.Shell.workspace()}
  def route_event(%__MODULE__{} = runtime, workspace, event) do
    {shell_state, workspace} = runtime.entry.module.handle_event(runtime.state, workspace, event)
    {%__MODULE__{runtime | state: shell_state}, workspace}
  end

  @doc "Routes a shell GUI action through the active entry's contract."
  @spec route_gui_action(t(), MingaEditor.Shell.workspace(), term()) ::
          {t(), MingaEditor.Shell.workspace()}
  def route_gui_action(%__MODULE__{} = runtime, workspace, action) do
    {shell_state, workspace} =
      runtime.entry.module.handle_gui_action(runtime.state, workspace, action)

    {%__MODULE__{runtime | state: shell_state}, workspace}
  end

  @doc "Routes an agent event through the active entry and returns effects as data."
  @spec route_agent_event(t(), MingaEditor.Shell.workspace(), pid(), term()) ::
          {t(), MingaEditor.Shell.workspace(), [MingaEditor.effect()], persistence_change() | nil}
  def route_agent_event(%__MODULE__{} = runtime, workspace, session_pid, event) do
    old_state = runtime.state

    {shell_state, workspace, effects} =
      runtime.entry.module.on_agent_event(old_state, workspace, session_pid, event)

    change = persistence_change(runtime.entry, old_state, shell_state)
    {%__MODULE__{runtime | state: shell_state}, workspace, effects, change}
  end

  @doc "Routes an agent event through exact-identity stashes using caller-resolved entries."
  @spec route_stashed_agent_event(t(), [Entry.t()], MingaEditor.Shell.workspace(), pid(), term()) ::
          {t(), MingaEditor.Shell.workspace(), [MingaEditor.effect()], [persistence_change()]}
  def route_stashed_agent_event(%__MODULE__{} = runtime, entries, workspace, session_pid, event) do
    entries_by_id = Map.new(entries, &{&1.id, &1})

    {stash, workspace, effects, changes} =
      Enum.reduce(runtime.stash, {%{}, workspace, [], []}, fn {id, stashed},
                                                              {stash_acc, workspace_acc,
                                                               effects_acc, changes_acc} ->
        case Map.get(entries_by_id, id) do
          %Entry{} = entry ->
            route_stashed_agent_value(
              stash_acc,
              effects_acc,
              changes_acc,
              stashed,
              entry,
              workspace_acc,
              session_pid,
              event
            )

          nil ->
            {Map.put(stash_acc, id, stashed), workspace_acc, effects_acc, changes_acc}
        end
      end)

    {%__MODULE__{runtime | stash: stash}, workspace, effects, changes}
  end

  @doc "Routes buffer-added lifecycle through the active shell and returns effects as data."
  @spec route_buffer_added(
          t(),
          MingaEditor.Shell.workspace(),
          MingaEditor.Shell.workspace(),
          pid(),
          MingaEditor.Shell.buffer_add_context()
        ) :: {t(), MingaEditor.Shell.workspace(), [MingaEditor.effect()]}
  def route_buffer_added(
        %__MODULE__{} = runtime,
        previous_workspace,
        workspace,
        buffer_pid,
        context
      ) do
    {shell_state, workspace, effects} =
      runtime.entry.module.on_buffer_added(
        runtime.state,
        previous_workspace,
        workspace,
        buffer_pid,
        context
      )

    {%__MODULE__{runtime | state: shell_state}, workspace, effects}
  end

  @doc "Routes buffer-switch lifecycle through the active shell and returns effects as data."
  @spec route_buffer_switched(t(), MingaEditor.Shell.workspace()) ::
          {t(), MingaEditor.Shell.workspace(), [MingaEditor.effect()]}
  def route_buffer_switched(%__MODULE__{} = runtime, workspace) do
    {shell_state, workspace, effects} =
      runtime.entry.module.on_buffer_switched(runtime.state, workspace)

    {%__MODULE__{runtime | state: shell_state}, workspace, effects}
  end

  @doc "Routes buffer-removal lifecycle through the active shell and returns effects as data."
  @spec route_buffer_died(t(), MingaEditor.Shell.workspace(), pid()) ::
          {t(), MingaEditor.Shell.workspace(), [MingaEditor.effect()]}
  def route_buffer_died(%__MODULE__{} = runtime, workspace, dead_pid) do
    {shell_state, workspace, effects} =
      runtime.entry.module.on_buffer_died(runtime.state, workspace, dead_pid)

    {%__MODULE__{runtime | state: shell_state}, workspace, effects}
  end

  @doc "Routes an optional active session-down transition through the active entry."
  @spec route_session_down(t(), pid(), term()) :: {t(), boolean(), persistence_change() | nil}
  def route_session_down(%__MODULE__{} = runtime, session_pid, reason) do
    route_active_boolean_callback(runtime, :handle_agent_session_down, [session_pid, reason])
  end

  @doc "Returns whether the active or an exact-identity stashed entry owns a session."
  @spec owns_agent_session?(t(), [Entry.t()], pid()) :: boolean()
  def owns_agent_session?(%__MODULE__{} = runtime, entries, session_pid) do
    active_owns_agent_session?(runtime, session_pid) or
      Enum.any?(entries, &stashed_entry_owns_agent_session?(runtime, &1, session_pid))
  end

  @doc "Routes session-down through the first exact-identity stash that owns it."
  @spec route_stashed_session_down(t(), [Entry.t()], pid(), term()) ::
          {t(), boolean(), [persistence_change()]}
  def route_stashed_session_down(%__MODULE__{} = runtime, entries, session_pid, reason) do
    route_first_stashed_boolean_callback(
      runtime,
      entries,
      :handle_agent_session_down,
      [session_pid, reason]
    )
  end

  @doc "Routes a session restart through the active and exact-identity stashed entries."
  @spec route_session_restarted(t(), [Entry.t()], pid(), pid(), term()) ::
          {t(), boolean(), [persistence_change()]}
  def route_session_restarted(%__MODULE__{} = runtime, entries, old_pid, new_pid, reason) do
    {runtime, active_handled?, active_change} =
      route_active_boolean_callback(runtime, :handle_agent_session_restarted, [
        old_pid,
        new_pid,
        reason
      ])

    {runtime, stashed_handled?, stash_changes} =
      route_all_stashed_boolean_callbacks(
        runtime,
        entries,
        :handle_agent_session_restarted,
        [old_pid, new_pid, reason]
      )

    changes = prepend_change(active_change, stash_changes)
    {runtime, active_handled? or stashed_handled?, changes}
  end

  @doc "Routes a remote disconnect through the active entry."
  @spec route_remote_session_disconnected(t(), pid()) ::
          {t(), boolean(), persistence_change() | nil}
  def route_remote_session_disconnected(%__MODULE__{} = runtime, session_pid) do
    route_active_boolean_callback(runtime, :handle_remote_session_disconnected, [session_pid])
  end

  @doc "Routes a remote disconnect through the first exact-identity stash that owns it."
  @spec route_stashed_remote_session_disconnected(t(), [Entry.t()], pid()) ::
          {t(), boolean(), [persistence_change()]}
  def route_stashed_remote_session_disconnected(
        %__MODULE__{} = runtime,
        entries,
        session_pid
      ) do
    route_first_stashed_boolean_callback(
      runtime,
      entries,
      :handle_remote_session_disconnected,
      [session_pid]
    )
  end

  @doc "Routes an optional agent status update through active and stashed entries."
  @spec sync_agent_status(t(), [Entry.t()], pid(), term()) :: t()
  def sync_agent_status(%__MODULE__{} = runtime, entries, session_pid, status) do
    route_optional_state_update(runtime, entries, :sync_agent_status, [session_pid, status])
  end

  @doc "Routes optional agent-file tracking through active and stashed entries."
  @spec track_agent_file(t(), [Entry.t()], pid(), String.t()) :: t()
  def track_agent_file(%__MODULE__{} = runtime, entries, session_pid, path) do
    route_optional_state_update(runtime, entries, :track_agent_file, [session_pid, path])
  end

  @doc "Drops extension feature state through active and exact-identity stashed shell callbacks."
  @spec drop_extension_feature_state_sources(t(), [Entry.t()]) :: t()
  def drop_extension_feature_state_sources(%__MODULE__{} = runtime, entries) do
    route_optional_state_update(runtime, entries, :drop_extension_feature_state_sources, [])
  end

  @doc "Drops one feature-state source through active and exact-identity stashed callbacks."
  @spec drop_feature_state_source(t(), [Entry.t()], MingaEditor.FeatureState.source()) :: t()
  def drop_feature_state_source(%__MODULE__{} = runtime, entries, source) do
    route_optional_state_update(runtime, entries, :drop_feature_state_source, [source])
  end

  @doc "Returns the active tab through the active shell contract."
  @spec active_tab(t()) :: MingaEditor.State.Tab.t() | nil
  def active_tab(%__MODULE__{} = runtime), do: runtime.entry.module.active_tab(runtime.state)

  @doc "Finds a tab through the active shell contract."
  @spec find_tab_by_buffer(t(), pid()) :: MingaEditor.State.Tab.t() | nil
  def find_tab_by_buffer(%__MODULE__{} = runtime, pid),
    do: runtime.entry.module.find_tab_by_buffer(runtime.state, pid)

  @doc "Returns the active tab kind through the active shell contract."
  @spec active_tab_kind(t()) :: atom()
  def active_tab_kind(%__MODULE__{} = runtime),
    do: runtime.entry.module.active_tab_kind(runtime.state)

  @doc "Associates a session with a shell tab through the active contract."
  @spec set_tab_session(t(), term(), pid() | nil) :: t()
  def set_tab_session(%__MODULE__{} = runtime, tab_id, session_pid) do
    shell_state = runtime.entry.module.set_tab_session(runtime.state, tab_id, session_pid)
    %__MODULE__{runtime | state: shell_state}
  end

  @doc "Returns the active session through the active shell contract."
  @spec active_session(t()) :: pid() | nil
  def active_session(%__MODULE__{} = runtime),
    do: runtime.entry.module.active_session(runtime.state)

  @spec restore_target(stash(), Entry.t(), shell_state()) :: {shell_state(), stash()}
  defp restore_target(stash, %Entry{} = target, initialized_state) do
    target_state =
      case Map.get(stash, target.id) do
        %StateStash{} = stashed ->
          case StateStash.restore(stashed, target) do
            {:ok, state} -> state
            :mismatch -> initialized_state
          end

        nil ->
          initialized_state
      end

    {target_state, Map.delete(stash, target.id)}
  end

  @spec route_stashed_agent_value(
          stash(),
          [MingaEditor.effect()],
          [persistence_change()],
          StateStash.t(),
          Entry.t(),
          MingaEditor.Shell.workspace(),
          pid(),
          term()
        ) ::
          {stash(), MingaEditor.Shell.workspace(), [MingaEditor.effect()], [persistence_change()]}
  defp route_stashed_agent_value(
         stash,
         effects,
         changes,
         %StateStash{} = stashed,
         %Entry{} = entry,
         workspace,
         session_pid,
         event
       ) do
    case StateStash.restore(stashed, entry) do
      {:ok, old_state} ->
        {new_state, workspace, new_effects} =
          entry.module.on_agent_event(old_state, workspace, session_pid, event)

        updated = StateStash.new(entry, new_state)
        change = persistence_change(entry, old_state, new_state)

        {
          Map.put(stash, entry.id, updated),
          workspace,
          effects ++ new_effects,
          prepend_change(change, changes)
        }

      :mismatch ->
        {Map.put(stash, entry.id, stashed), workspace, effects, changes}
    end
  end

  @spec active_owns_agent_session?(t(), pid()) :: boolean()
  defp active_owns_agent_session?(%__MODULE__{} = runtime, session_pid) do
    shell_state_owns_agent_session?(runtime.entry.module, runtime.state, session_pid)
  end

  @spec stashed_entry_owns_agent_session?(t(), Entry.t(), pid()) :: boolean()
  defp stashed_entry_owns_agent_session?(
         %__MODULE__{} = runtime,
         %Entry{} = entry,
         session_pid
       ) do
    case Map.get(runtime.stash, entry.id) do
      %StateStash{} = stashed ->
        case StateStash.restore(stashed, entry) do
          {:ok, state} -> shell_state_owns_agent_session?(entry.module, state, session_pid)
          :mismatch -> false
        end

      nil ->
        false
    end
  end

  @spec shell_state_owns_agent_session?(module(), shell_state(), pid()) :: boolean()
  defp shell_state_owns_agent_session?(module, shell_state, session_pid) do
    if function_exported?(module, :owns_agent_session?, 2) do
      module.owns_agent_session?(shell_state, session_pid)
    else
      module.active_session(shell_state) == session_pid or
        legacy_shell_state_owns_agent_session?(shell_state, session_pid)
    end
  end

  @spec legacy_shell_state_owns_agent_session?(shell_state(), pid()) :: boolean()
  defp legacy_shell_state_owns_agent_session?(%{cards: cards} = shell_state, session_pid)
       when is_map(cards) do
    Enum.any?(cards, fn {_card_id, card} -> Map.get(card, :session) == session_pid end) or
      legacy_tab_bar_owns_agent_session?(shell_state, session_pid)
  end

  defp legacy_shell_state_owns_agent_session?(shell_state, session_pid),
    do: legacy_tab_bar_owns_agent_session?(shell_state, session_pid)

  @spec legacy_tab_bar_owns_agent_session?(shell_state(), pid()) :: boolean()
  defp legacy_tab_bar_owns_agent_session?(%{tab_bar: %TabBar{} = tab_bar}, session_pid) do
    not is_nil(TabBar.find_by_session(tab_bar, session_pid)) or
      not is_nil(TabBar.find_workspace_by_session(tab_bar, session_pid))
  end

  defp legacy_tab_bar_owns_agent_session?(_shell_state, _session_pid), do: false

  @spec route_active_boolean_callback(t(), atom(), [term()]) ::
          {t(), boolean(), persistence_change() | nil}
  defp route_active_boolean_callback(%__MODULE__{} = runtime, callback, args) do
    module = runtime.entry.module

    if function_exported?(module, callback, length(args) + 1) do
      old_state = runtime.state
      {new_state, handled?} = apply(module, callback, [old_state | args])
      change = if handled?, do: persistence_change(runtime.entry, old_state, new_state), else: nil
      {%__MODULE__{runtime | state: new_state}, handled?, change}
    else
      {runtime, false, nil}
    end
  end

  @spec route_all_stashed_boolean_callbacks(t(), [Entry.t()], atom(), [term()]) ::
          {t(), boolean(), [persistence_change()]}
  defp route_all_stashed_boolean_callbacks(%__MODULE__{} = runtime, entries, callback, args) do
    Enum.reduce(entries, {runtime, false, []}, fn entry, {runtime_acc, handled_acc, changes} ->
      case route_one_stashed_boolean_callback(runtime_acc, entry, callback, args) do
        {runtime_next, handled?, change} ->
          {runtime_next, handled_acc or handled?, prepend_change(change, changes)}
      end
    end)
  end

  @spec route_first_stashed_boolean_callback(t(), [Entry.t()], atom(), [term()]) ::
          {t(), boolean(), [persistence_change()]}
  defp route_first_stashed_boolean_callback(
         %__MODULE__{} = runtime,
         entries,
         callback,
         args
       ) do
    Enum.reduce_while(entries, {runtime, false, []}, fn entry, {runtime_acc, false, changes} ->
      case route_one_stashed_boolean_callback(runtime_acc, entry, callback, args) do
        {runtime_next, true, change} ->
          {:halt, {runtime_next, true, prepend_change(change, changes)}}

        {runtime_next, false, _change} ->
          {:cont, {runtime_next, false, changes}}
      end
    end)
  end

  @spec route_one_stashed_boolean_callback(t(), Entry.t(), atom(), [term()]) ::
          {t(), boolean(), persistence_change() | nil}
  defp route_one_stashed_boolean_callback(
         %__MODULE__{} = runtime,
         %Entry{} = entry,
         callback,
         args
       ) do
    case Map.get(runtime.stash, entry.id) do
      %StateStash{} = stashed ->
        route_matching_stashed_boolean_callback(runtime, stashed, entry, callback, args)

      nil ->
        {runtime, false, nil}
    end
  end

  @spec route_matching_stashed_boolean_callback(t(), StateStash.t(), Entry.t(), atom(), [term()]) ::
          {t(), boolean(), persistence_change() | nil}
  defp route_matching_stashed_boolean_callback(
         %__MODULE__{} = runtime,
         %StateStash{} = stashed,
         %Entry{} = entry,
         callback,
         args
       ) do
    with {:ok, old_state} <- StateStash.restore(stashed, entry),
         true <- function_exported?(entry.module, callback, length(args) + 1) do
      case apply(entry.module, callback, [old_state | args]) do
        {new_state, true} ->
          updated = StateStash.new(entry, new_state)
          runtime = %__MODULE__{runtime | stash: Map.put(runtime.stash, entry.id, updated)}
          change = persistence_change(entry, old_state, new_state)
          {runtime, true, change}

        {_new_state, false} ->
          {runtime, false, nil}
      end
    else
      _ -> {runtime, false, nil}
    end
  end

  @spec route_optional_state_update(t(), [Entry.t()], atom(), [term()]) :: t()
  defp route_optional_state_update(%__MODULE__{} = runtime, entries, callback, args) do
    runtime = route_active_optional_state_update(runtime, callback, args)

    Enum.reduce(entries, runtime, fn entry, runtime_acc ->
      route_stashed_optional_state_update(runtime_acc, entry, callback, args)
    end)
  end

  @spec route_active_optional_state_update(t(), atom(), [term()]) :: t()
  defp route_active_optional_state_update(%__MODULE__{} = runtime, callback, args) do
    if function_exported?(runtime.entry.module, callback, length(args) + 1) do
      state = apply(runtime.entry.module, callback, [runtime.state | args])
      %__MODULE__{runtime | state: state}
    else
      runtime
    end
  end

  @spec route_stashed_optional_state_update(t(), Entry.t(), atom(), [term()]) :: t()
  defp route_stashed_optional_state_update(
         %__MODULE__{} = runtime,
         %Entry{} = entry,
         callback,
         args
       ) do
    case Map.get(runtime.stash, entry.id) do
      %StateStash{} = stashed ->
        with {:ok, old_state} <- StateStash.restore(stashed, entry),
             true <- function_exported?(entry.module, callback, length(args) + 1) do
          new_state = apply(entry.module, callback, [old_state | args])
          updated = StateStash.new(entry, new_state)
          %__MODULE__{runtime | stash: Map.put(runtime.stash, entry.id, updated)}
        else
          _ -> runtime
        end

      nil ->
        runtime
    end
  end

  @spec accept_stashed_persisted_state(t(), Entry.t(), shell_state()) :: t()
  defp accept_stashed_persisted_state(%__MODULE__{} = runtime, %Entry{} = entry, persisted_state) do
    case Map.get(runtime.stash, entry.id) do
      %StateStash{} = stashed ->
        if StateStash.matches?(stashed, entry) do
          stash = Map.put(runtime.stash, entry.id, StateStash.new(entry, persisted_state))
          %__MODULE__{runtime | stash: stash}
        else
          runtime
        end

      nil ->
        runtime
    end
  end

  @spec persistence_change(Entry.t(), shell_state(), shell_state()) :: persistence_change() | nil
  defp persistence_change(_entry, state, state), do: nil
  defp persistence_change(entry, old_state, new_state), do: {entry, old_state, new_state}

  @spec prepend_change(persistence_change() | nil, [persistence_change()]) ::
          [persistence_change()]
  defp prepend_change(nil, changes), do: changes
  defp prepend_change(change, changes), do: [change | changes]

  @spec same_entry?(Entry.t(), Entry.t()) :: boolean()
  defp same_entry?(%Entry{} = left, %Entry{} = right) do
    left.id == right.id and left.module == right.module and left.source == right.source and
      left.generation == right.generation
  end
end
