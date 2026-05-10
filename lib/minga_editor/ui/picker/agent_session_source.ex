defmodule MingaEditor.UI.Picker.AgentSessionSource do
  @moduledoc """
  Picker source for agent sessions.

  Lists all live sessions (active + archived) plus persisted sessions from disk. Selecting a live session switches tabs; selecting a persisted session resumes it into the active agent session. Entries include title, last message time, turn count, model, and recent message text for filtering.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  alias MingaAgent.Session
  alias MingaAgent.SessionStore
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar

  @impl true
  @spec title() :: String.t()
  def title, do: "Sessions"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: false

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{tab_bar: %TabBar{} = tb} = ctx) do
    disk = disk_candidates(ctx)

    if persisted_only?(ctx) do
      disk
    else
      live = tab_candidates(tb)
      live_ids = MapSet.new(live, fn %Item{id: {id, _}} -> id end)

      live ++
        Enum.reject(disk, fn %Item{id: {id, _}} -> MapSet.member?(live_ids, id) end)
    end
  end

  def candidates(_state), do: []

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {_id, {:tab, tab_id}}}, state) do
    EditorState.switch_tab(state, tab_id)
  end

  def on_select(%Item{id: {session_id, :disk}}, state) do
    case AgentAccess.session(state) do
      nil ->
        state

      session_pid ->
        Session.load_session(session_pid, session_id)
        state
    end
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec tab_candidates(TabBar.t()) :: [Item.t()]
  defp tab_candidates(tb) do
    tb
    |> TabBar.filter_by_kind(:agent)
    |> Enum.map(&tab_to_candidate(&1, &1.id == tb.active_id))
  end

  @spec tab_to_candidate(Tab.t(), boolean()) :: Item.t()
  defp tab_to_candidate(tab, is_active) do
    case session_metadata(tab.session) do
      {:ok, meta} ->
        %Item{
          id: {meta.id, {:tab, tab.id}},
          label: format_label(meta, is_active),
          description: format_desc(meta)
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

  @spec disk_candidates(Context.t()) :: [Item.t()]
  defp disk_candidates(ctx) do
    ctx
    |> session_store_dir()
    |> SessionStore.list()
    |> Enum.map(fn meta ->
      %Item{
        id: {meta.id, :disk},
        label: meta.title,
        description: disk_description(meta),
        annotation: format_turn_count(meta.turn_count)
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

  @spec disk_description(SessionStore.session_meta()) :: String.t()
  defp disk_description(meta) do
    [
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

    "#{meta.provider_name}/#{meta.model_name} · #{format_turn_count(meta.turn_count)} · #{meta.message_count} msgs · $#{cost} · #{time}"
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
