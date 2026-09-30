defmodule MingaEditor.UI.Picker.AgentSessionSource do
  @moduledoc """
  Picker source for agent sessions.

  Lists all live sessions (active + archived) plus persisted sessions from disk. Selecting a live session switches tabs; selecting a persisted session resumes it into the active agent session. Entries include title, last message time, turn count, model, and recent message text for filtering.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Distribution.ConnectionManager
  alias MingaEditor.Remote.SessionClient
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  alias MingaAgent.Session
  alias MingaAgent.SessionStore
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Agent, as: TabAgent
  alias MingaEditor.State.TabBar
  alias MingaEditor.Commands.Agent

  @impl true
  @spec title() :: String.t()
  def title, do: "Sessions"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{tab_bar: %TabBar{} = tb} = ctx) do
    disk = disk_candidates(ctx)

    if persisted_only?(ctx) do
      disk
    else
      live = tab_candidates(tb) ++ remote_candidates()
      live_ids = MapSet.new(live, fn %Item{id: {id, _}} -> id end)

      live ++
        Enum.reject(disk, fn %Item{id: {id, _}} -> MapSet.member?(live_ids, id) end)
    end
  end

  def candidates(_state), do: []

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {_id, {:tab, tab_id}}}, state) do
    MingaEditor.TabWorkflow.switch(state, tab_id)
  end

  def on_select(%Item{id: {_id, {:remote, server_name, session_id, remote_pid, token}}}, state) do
    Agent.connect_remote_session(state, server_name, session_id, remote_pid, token)
  end

  def on_select(%Item{id: {session_id, :disk}}, state) do
    case MingaEditor.Shell.Runtime.active_session(state.shell_runtime) do
      nil ->
        state

      session_pid ->
        case Session.load_session(session_pid, session_id) do
          :ok ->
            state

          {:error, reason} ->
            MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
              state,
              "Could not load agent session: #{inspect(reason)}"
            )
        end
    end
  end

  def on_select(%Item{id: {session_id, :legacy_import}}, state) do
    case MingaEditor.Shell.Runtime.active_session(state.shell_runtime) do
      nil ->
        state

      session_pid ->
        case Session.import_legacy_session(session_pid, session_id) do
          :ok ->
            state

          {:error, reason} ->
            Minga.Log.warning(
              :agent,
              "[Agent.SessionSource] legacy import failed for #{session_id}: #{inspect(reason)}"
            )

            MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
              state,
              legacy_import_failure_message(reason)
            )
        end
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec legacy_import_failure_message(term()) :: String.t()
  defp legacy_import_failure_message({:legacy_import_persistence_failed, _reason}),
    do: "Could not save the imported history. The original legacy record remains unchanged."

  defp legacy_import_failure_message({:legacy_import_saved_but_restore_failed, _reason}),
    do:
      "The imported copy was saved but could not be opened. The original legacy record remains unchanged."

  defp legacy_import_failure_message(_reason),
    do: "Could not import legacy agent history. The original record remains unchanged."

  @spec tab_candidates(TabBar.t()) :: [Item.t()]
  defp tab_candidates(tb) do
    tb
    |> TabBar.filter_by_kind(:agent)
    |> Enum.map(&tab_to_candidate(&1, &1.id == tb.active_id))
  end

  @spec tab_to_candidate(Tab.agent(), boolean()) :: Item.t()
  defp tab_to_candidate(%Tab{kind: :agent, payload: %TabAgent{session: session}} = tab, is_active) do
    case session_metadata(session) do
      {:ok, meta} ->
        %Item{
          id: {meta.id, {:tab, tab.id}},
          label: format_label(meta, is_active),
          description: format_desc(meta),
          search_text: meta.first_prompt || ""
        }

      :error ->
        label = if is_active, do: "\u{2022} #{tab.label}", else: tab.label
        %Item{id: {tab.id, {:tab, tab.id}}, label: label, description: "No session"}
    end
  end

  @spec session_metadata(pid() | nil) :: {:ok, Session.metadata()} | :error
  defp session_metadata(nil), do: :error

  defp session_metadata(pid) do
    {:ok, Session.metadata(pid)}
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

  @spec disk_candidates(Context.t()) :: [Item.t()]
  defp disk_candidates(ctx) do
    ctx
    |> session_store_dir()
    |> SessionStore.list()
    |> Enum.map(fn meta ->
      %Item{
        id: {meta.id, disk_candidate_kind(meta.continuation_kind)},
        label: disk_label(meta),
        description: disk_description(meta),
        annotation: format_turn_count(meta.turn_count),
        search_text: "#{meta.preview} #{meta.recent_messages}"
      }
    end)
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
  defp format_label(meta, true) do
    prompt = truncate_prompt(meta.title || meta.first_prompt)
    "\u{2022} #{prompt}"
  end

  defp format_label(meta, false) do
    truncate_prompt(meta.title || meta.first_prompt)
  end

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
