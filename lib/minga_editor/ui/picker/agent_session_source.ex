defmodule MingaEditor.UI.Picker.AgentSessionSource do
  @moduledoc """
  Picker source for agent sessions.

  Select a live session to switch tabs or reopen a saved conversation. Archived saved sessions have a separate view. Open tabs remain visible so archiving cannot hide active work.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Distribution.ConnectionManager
  alias MingaEditor.Remote.SessionClient
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  alias MingaAgent.Session
  alias MingaAgent.SessionStore
  alias MingaAgent.Session.ConnectionTarget
  alias MingaEditor.Agent.SessionOrganization
  alias MingaEditor.PickerUI
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Agent, as: TabAgent
  alias MingaEditor.State.TabBar
  alias MingaEditor.Commands.Agent
  alias MingaEditor.Agent.DraftWorkflow

  @typep saved_kind :: :disk | :draft_only | :legacy_import
  @typep saved_origin :: {non_neg_integer(), pid(), String.t()}

  @doc "Opens Sessions with the exact displayed conversation for organization actions."
  @spec open(State.t(), map()) :: State.t()
  def open(state, context \\ %{}) do
    context = Map.put(context, :organization_origin, SessionOrganization.origin(state))
    PickerUI.open(state, __MODULE__, context)
  end

  @impl true
  @spec title() :: String.t()
  def title, do: "Sessions"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{tab_bar: %TabBar{} = tabs} = ctx) do
    {archived, recent} =
      ctx
      |> session_store_dir()
      |> SessionStore.list_recoverable()
      |> Enum.split_with(&archived_recovery?/1)

    origin = saved_origin(ctx)

    if archive_view?(ctx) do
      [
        archive_navigation(ctx, :recent)
        | merge_candidates(local_candidates(ctx, tabs, :archived), archived, origin)
      ]
    else
      local_candidates(ctx, tabs, :recent)
      |> merge_candidates(recent, origin)
      |> maybe_add_archive_navigation(archived, ctx)
      |> maybe_add_archive_action(ctx, recent, archived)
    end
  end

  def candidates(_state), do: []

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {:archive_navigation, context}}, state) do
    open(state, context)
  end

  def on_select(%Item{id: {:archive_session, displayed, next}}, state) do
    if SessionOrganization.origin(state) == displayed do
      SessionOrganization.start(state, displayed, {:archive, next})
    else
      NoticeWorkflow.publish(state, "Session changed. Reopen Sessions.")
    end
  end

  def on_select(
        %Item{id: {id, {:tab, tab_id, session}}},
        %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tab_bar}}} = state
      ) do
    with %Tab{kind: :agent, payload: %TabAgent{session: ^session}} <- TabBar.get(tab_bar, tab_id),
         true <- current_tab_session?(id, tab_id, session) do
      state
      |> MingaEditor.TabWorkflow.switch(tab_id)
      |> DraftWorkflow.recover_recall_conflict(session, id)
    else
      _changed -> NoticeWorkflow.publish(state, "Session changed. Reopen Sessions.")
    end
  end

  def on_select(%Item{id: {_id, {:tab, _tab_id, _session}}}, state), do: state

  def on_select(%Item{id: {_id, {:remote, server_name, session_id, remote_pid, token}}}, state) do
    Agent.connect_remote_session(state, server_name, session_id, remote_pid, token)
  end

  def on_select(
        %Item{id: {session_id, {kind, {owner, session, origin_id}}}},
        %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tab_bar}}} = state
      )
      when kind in [:disk, :draft_only, :legacy_import] do
    with ^owner <- TabBar.active_workspace_id(tab_bar),
         ^session <- MingaEditor.Shell.Runtime.active_session(state.shell_runtime),
         true <- current_tab_session?(origin_id, tab_bar.active_id, session),
         :ok <- DraftWorkflow.before_reopen(state, session_id) do
      reopen_saved(state, session, origin_id, session_id, kind)
    else
      {:error, updated} -> updated
      _changed -> NoticeWorkflow.publish(state, "Session changed. Reopen Sessions.")
    end
  end

  def on_select(%Item{id: {_id, {kind, nil}}}, state)
      when kind in [:disk, :draft_only, :legacy_import],
      do: NoticeWorkflow.publish(state, "Open an Agent workspace, then reopen Sessions.")

  @spec reopen_saved(term(), pid(), String.t(), String.t(), saved_kind()) :: term()
  defp reopen_saved(state, session, origin_id, id, kind) do
    case restore_saved(session, id, origin_id, kind) do
      :ok ->
        ui = MingaEditor.Agent.UIState.reset_edit_timeline(state.workspace.agent_ui)

        state
        |> MingaEditor.Shell.Traditional.Workflow.install_agent_ui(ui)
        |> DraftWorkflow.after_reopen(session, id)

      {:error, :stale_session} ->
        NoticeWorkflow.publish(state, "Session changed. Reopen Sessions.")

      {:error, :restore_unconfirmed} ->
        NoticeWorkflow.publish(state, "Could not confirm that the saved Agent session opened.")

      {:error, reason} when kind == :legacy_import ->
        Minga.Log.warning(
          :agent,
          "[Agent.SessionSource] legacy import failed for #{id}: #{inspect(reason)}"
        )

        NoticeWorkflow.publish(state, legacy_import_failure_message(reason))

      {:error, _reason} ->
        NoticeWorkflow.publish(state, "Could not open saved Agent session.")
    end
  end

  @spec restore_saved(pid(), String.t(), String.t(), saved_kind()) :: :ok | {:error, term()}
  defp restore_saved(session, id, origin_id, kind) do
    case kind do
      :legacy_import -> Session.import_legacy_session(session, id, origin_id)
      _saved -> Session.load_session(session, id, origin_id)
    end
  catch
    :exit, {:timeout, _call} -> {:error, :restore_unconfirmed}
    :exit, _reason -> {:error, :stale_session}
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec current_tab_session?(String.t() | Tab.id(), Tab.id(), pid() | nil) :: boolean()
  defp current_tab_session?(tab_id, tab_id, nil), do: true

  defp current_tab_session?(id, _tab_id, pid) when is_binary(id) and is_pid(pid) do
    Session.session_id(pid) == id
  catch
    :exit, _reason -> false
  end

  defp current_tab_session?(_id, _tab_id, _session), do: false

  @spec legacy_import_failure_message(term()) :: String.t()
  defp legacy_import_failure_message({:legacy_import_persistence_failed, _reason}),
    do: "Could not save the imported history. The original legacy record remains unchanged."

  defp legacy_import_failure_message({:legacy_import_saved_but_restore_failed, _reason}),
    do:
      "The imported copy was saved but could not be opened. The original legacy record remains unchanged."

  defp legacy_import_failure_message(_reason),
    do: "Could not import legacy agent history. The original record remains unchanged."

  @spec tab_candidates(TabBar.t(), :recent | :archived) :: [Item.t()]
  defp tab_candidates(tabs, view) do
    tabs
    |> TabBar.filter_by_kind(:agent)
    |> Enum.flat_map(&tab_candidate(&1, &1.id == tabs.active_id, view))
  end

  @spec tab_candidate(Tab.agent(), boolean(), :recent | :archived) :: [Item.t()]
  defp tab_candidate(%Tab{payload: %TabAgent{session: session}} = tab, active?, view) do
    case session_metadata(session) do
      {:ok, meta} when view == :recent or meta.archived? ->
        [
          %Item{
            id: {meta.id, {:tab, tab.id, session}},
            label: format_label(meta, active?),
            description: format_desc(meta),
            search_text: meta.first_prompt || "",
            annotation: archive_annotation(meta)
          }
        ]

      :error when view == :recent ->
        label = if active?, do: "\u{2022} #{tab.label}", else: tab.label
        description = if is_nil(session), do: "No session", else: "Session identity unavailable"
        [%Item{id: {tab.id, {:tab, tab.id, session}}, label: label, description: description}]

      _outside_view ->
        []
    end
  end

  @spec session_metadata(pid() | nil) :: {:ok, Session.metadata()} | :error
  defp session_metadata(nil), do: :error

  defp session_metadata(pid) do
    # An attached daemon can predate the archive field in SessionMetadata.
    {:ok, Map.put_new(Session.metadata(pid), :archived?, false)}
  catch
    :exit, _ -> :error
  end

  @spec remote_candidates() :: [Item.t()]
  defp remote_candidates do
    ConnectionManager.connected_nodes()
    |> Enum.filter(fn {_server_name, _node, status} -> status == :connected end)
    |> Enum.flat_map(&remote_sessions_for_node/1)
  end

  @spec remote_sessions_for_node({String.t(), node(), atom()}) :: [Item.t()]
  defp remote_sessions_for_node({server_name, remote_node, _status}) do
    case SessionClient.list_sessions(remote_node) do
      {:ok, sessions} ->
        Enum.map(sessions, &remote_session_item(server_name, &1))

      {:error, reason} ->
        Minga.Log.warning(
          :distribution,
          "Failed to list sessions on #{server_name}: #{inspect(reason)}"
        )

        []
    end
  end

  @doc false
  @spec remote_session_item(String.t(), MingaAgent.RemoteAPI.session_info()) :: Item.t()
  def remote_session_item(server_name, %{
        session_id: session_id,
        pid: remote_pid,
        token: token,
        details: {:available, meta}
      }) do
    %Item{
      id:
        {{:remote, server_name, session_id},
         {:remote, server_name, session_id, remote_pid, token}},
      label:
        "[#{server_name}] #{truncate_prompt(Map.get(meta, :title) || Map.get(meta, :first_prompt) || session_id)}",
      description: remote_description(meta),
      annotation: meta |> Map.fetch!(:status) |> Atom.to_string()
    }
  end

  def remote_session_item(server_name, %{
        session_id: session_id,
        pid: remote_pid,
        token: token,
        details: {:unavailable, reason}
      }) do
    %Item{
      id:
        {{:remote, server_name, session_id},
         {:remote, server_name, session_id, remote_pid, token}},
      label: "[#{server_name}] #{session_id}",
      description: "Metadata unavailable (#{unavailable_reason_text(reason)})",
      annotation: "unavailable",
      search_text: session_id
    }
  end

  @spec remote_description(MingaAgent.RemoteAPI.SessionInfo.metadata()) :: String.t()
  defp remote_description(meta) do
    created = meta |> Map.fetch!(:created_at) |> Calendar.strftime("%b %d %H:%M")
    provider = Map.fetch!(meta, :provider_name)
    model = Map.fetch!(meta, :model_name)
    message_count = Map.fetch!(meta, :message_count)
    "#{provider}/#{model} · #{message_count} msgs · #{created}"
  end

  @spec unavailable_reason_text(MingaAgent.SessionListing.unavailable_reason()) :: String.t()
  defp unavailable_reason_text(:timeout), do: "timed out"
  defp unavailable_reason_text(:unreachable), do: "session unreachable"
  defp unavailable_reason_text(:invalid_details), do: "invalid details"

  @spec archived_recovery?(SessionStore.recovery_entry()) :: boolean()
  defp archived_recovery?({:conversation, %{archived?: true}}), do: true
  defp archived_recovery?(_entry), do: false

  @spec archive_view?(Context.t()) :: boolean()
  defp archive_view?(%Context{picker_ui: %{context: %{archive_view: true}}}), do: true
  defp archive_view?(_ctx), do: false

  @spec archive_navigation(Context.t(), :recent | :archived) :: Item.t()
  defp archive_navigation(ctx, destination) do
    context = %{
      archive_view: destination == :archived,
      persisted_only: persisted_only?(ctx),
      session_store_dir: session_store_dir(ctx)
    }

    label =
      if destination == :archived, do: "Browse archived sessions", else: "Back to recent sessions"

    %Item{id: {:archive_navigation, context}, label: label}
  end

  @spec maybe_add_archive_navigation([Item.t()], [SessionStore.recovery_entry()], Context.t()) ::
          [Item.t()]
  defp maybe_add_archive_navigation(items, [], _ctx), do: items

  defp maybe_add_archive_navigation(items, _archived, ctx),
    do: insert_control(items, archive_navigation(ctx, :archived))

  @spec maybe_add_archive_action(
          [Item.t()],
          Context.t(),
          [SessionStore.recovery_entry()],
          [SessionStore.recovery_entry()]
        ) :: [Item.t()]
  defp maybe_add_archive_action(
         items,
         %Context{
           picker_ui: %{
             context: %{
               organization_origin: %{target: %ConnectionTarget{session_id: id}} = displayed
             }
           }
         } = ctx,
         recent,
         archived
       ) do
    with nil <- session_store_dir(ctx),
         %{archived?: archived?} <-
           find_saved_conversation(recent, id) || find_saved_conversation(archived, id) do
      label = if archived?, do: "Unarchive Agent session", else: "Archive Agent session"
      action = %Item{id: {:archive_session, displayed, not archived?}, label: label}
      insert_control(items, action)
    else
      _not_saved -> items
    end
  end

  defp maybe_add_archive_action(items, _ctx, _recent, _archived), do: items

  @spec find_saved_conversation([SessionStore.recovery_entry()], String.t()) ::
          SessionStore.session_meta() | nil
  defp find_saved_conversation(entries, id) do
    Enum.find_value(entries, fn
      {:conversation, %{id: ^id} = meta} -> meta
      _entry -> nil
    end)
  end

  @spec insert_control([Item.t()], Item.t()) :: [Item.t()]
  defp insert_control([], control), do: [control]
  defp insert_control([first | rest], control), do: [first, control | rest]

  @spec local_candidates(Context.t(), TabBar.t(), :recent | :archived) :: [Item.t()]
  defp local_candidates(ctx, tabs, view) do
    if persisted_only?(ctx), do: [], else: live_candidates(tabs, view)
  end

  @spec live_candidates(TabBar.t(), :recent | :archived) :: [Item.t()]
  defp live_candidates(tabs, :recent), do: tab_candidates(tabs, :recent) ++ remote_candidates()
  defp live_candidates(tabs, :archived), do: tab_candidates(tabs, :archived)

  @spec merge_candidates([Item.t()], [SessionStore.recovery_entry()], saved_origin() | nil) ::
          [Item.t()]
  defp merge_candidates([], entries, origin), do: Enum.map(entries, &recovery_candidate(&1, origin))
  defp merge_candidates(live, [], _origin), do: live

  defp merge_candidates(live, entries, origin) do
    live_ids = MapSet.new(live, fn %Item{id: {id, _}} -> id end)

    disk =
      for entry <- entries, not MapSet.member?(live_ids, recovery_id(entry)) do
        recovery_candidate(entry, origin)
      end

    live ++ disk
  end

  @spec recovery_id(SessionStore.recovery_entry()) :: String.t()
  defp recovery_id({:conversation, %{id: id}}), do: id
  defp recovery_id({:draft_only, id, _timestamp}), do: id

  @spec saved_origin(Context.t()) :: saved_origin() | nil
  defp saved_origin(%Context{tab_bar: %TabBar{} = tab_bar, agent_session: session})
       when is_pid(session) do
    {TabBar.active_workspace_id(tab_bar), session, Session.session_id(session)}
  catch
    :exit, _reason -> nil
  end

  defp saved_origin(_context), do: nil

  @spec recovery_candidate(SessionStore.recovery_entry(), saved_origin() | nil) :: Item.t()
  defp recovery_candidate({:conversation, meta}, origin) do
    %Item{
      id: {meta.id, {disk_candidate_kind(meta.continuation_kind), origin}},
      label: archive_label(meta.archived?, disk_label(meta)),
      description: disk_description(meta),
      annotation: format_turn_count(meta.turn_count),
      search_text: "#{meta.preview} #{meta.recent_messages}"
    }
  end

  defp recovery_candidate({:draft_only, id, timestamp}, origin) do
    %Item{
      id: {id, {:draft_only, origin}},
      label: "Unsent Agent draft",
      description: "No conversation yet · #{format_disk_timestamp(timestamp)}"
    }
  end

  @spec persisted_only?(Context.t()) :: boolean()
  defp persisted_only?(%Context{picker_ui: %{context: %{persisted_only: true}}}), do: true
  defp persisted_only?(_ctx), do: false

  @spec session_store_dir(Context.t()) :: String.t() | nil
  defp session_store_dir(%Context{picker_ui: %{context: %{session_store_dir: dir}}})
       when is_binary(dir), do: dir

  defp session_store_dir(_ctx), do: nil

  @spec disk_candidate_kind(:lossless | :legacy_reconstructed | :legacy_import_required) ::
          :disk | :legacy_import
  defp disk_candidate_kind(kind) when kind in [:lossless, :legacy_reconstructed], do: :disk
  defp disk_candidate_kind(:legacy_import_required), do: :legacy_import

  @spec disk_label(SessionStore.session_meta()) :: String.t()
  defp disk_label(%{continuation_kind: :legacy_import_required, title: title}),
    do: "[Legacy portable import] #{title}"

  defp disk_label(%{continuation_kind: :legacy_reconstructed, title: title}),
    do: "[Reconstructed continuation] #{title}"

  defp disk_label(meta), do: meta.title

  @spec disk_description(SessionStore.session_meta()) :: String.t()
  defp disk_description(meta) do
    continuation =
      case meta.continuation_kind do
        :lossless -> "lossless continuation"
        :legacy_reconstructed -> "reconstructed continuation; original data was lossy"
        :legacy_import_required -> "reconstructed text; original preserved"
      end

    [
      continuation,
      "#{meta.provider_name}/#{meta.model_name}",
      format_turn_count(meta.turn_count),
      format_disk_timestamp(meta.last_message_at),
      meta.recent_messages
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  @spec format_label(Session.metadata(), boolean()) :: String.t()
  defp format_label(meta, active?) do
    label = archive_label(meta.archived?, truncate_prompt(meta.title || meta.first_prompt))
    if active?, do: "\u{2022} #{label}", else: label
  end

  @spec archive_label(boolean(), String.t()) :: String.t()
  defp archive_label(true, label), do: "[Archived] #{label}"
  defp archive_label(false, label), do: label

  @spec archive_annotation(Session.metadata()) :: String.t() | nil
  defp archive_annotation(%{archived?: true, status: status}), do: Atom.to_string(status)
  defp archive_annotation(_meta), do: nil

  @spec format_desc(Session.metadata()) :: String.t()
  defp format_desc(meta) do
    time = Calendar.strftime(meta.last_message_at, "%H:%M")
    cost = Float.round(meta.cost, 4)

    parts = [
      "#{meta.provider_name}/#{meta.model_name}",
      format_turn_count(meta.turn_count),
      "#{meta.message_count} msgs",
      "$#{cost}",
      time
    ]

    Enum.join(parts, " · ")
  end

  @spec format_disk_timestamp(String.t()) :: String.t()
  defp format_disk_timestamp(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _offset} -> Calendar.strftime(dt, "%b %d %H:%M")
      _ -> timestamp
    end
  end

  @spec format_turn_count(non_neg_integer()) :: String.t()
  defp format_turn_count(1), do: "1 turn"
  defp format_turn_count(count), do: "#{count} turns"

  @spec truncate_prompt(String.t() | nil) :: String.t()
  defp truncate_prompt(nil), do: "(new session)"
  defp truncate_prompt(""), do: "(new session)"

  defp truncate_prompt(text) do
    first_line = text |> String.split("\n") |> hd()

    if String.length(first_line) > 60 do
      String.slice(first_line, 0, 57) <> "..."
    else
      first_line
    end
  end
end
