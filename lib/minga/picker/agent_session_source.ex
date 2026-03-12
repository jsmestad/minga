defmodule Minga.Picker.AgentSessionSource do
  @moduledoc """
  Picker source for agent sessions.

  Lists all live sessions (active + archived) plus persisted sessions
  from disk. Selecting a session switches the conversation. Includes
  timestamp, first prompt preview, message count, and cost.
  """

  @behaviour Minga.Picker.Source

  alias Minga.Agent.Session
  alias Minga.Agent.SessionStore
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar

  @impl true
  @spec title() :: String.t()
  def title, do: "Sessions"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: false

  @impl true
  @spec candidates(term()) :: [Minga.Picker.item()]
  def candidates(%{tab_bar: %TabBar{} = tb} = _state) do
    live = tab_candidates(tb)
    disk = disk_candidates()
    live_ids = MapSet.new(live, fn {{id, _}, _, _} -> id end)

    live ++
      Enum.reject(disk, fn {{id, _}, _, _} -> MapSet.member?(live_ids, id) end)
  end

  def candidates(_state), do: []

  @impl true
  @spec on_select(Minga.Picker.item(), term()) :: term()
  def on_select({{_id, {:tab, tab_id}}, _label, _desc}, state) do
    EditorState.switch_tab(state, tab_id)
  end

  def on_select({{session_id, :disk}, _label, _desc}, state) do
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

  @spec tab_candidates(TabBar.t()) :: [Minga.Picker.item()]
  defp tab_candidates(tb) do
    tb
    |> TabBar.filter_by_kind(:agent)
    |> Enum.map(&tab_to_candidate(&1, &1.id == tb.active_id))
  end

  @spec tab_to_candidate(Tab.t(), boolean()) :: Minga.Picker.item()
  defp tab_to_candidate(tab, is_active) do
    case session_metadata(tab.session) do
      {:ok, meta} ->
        {{meta.id, {:tab, tab.id}}, format_label(meta, is_active), format_desc(meta)}

      :error ->
        label = if is_active, do: "\u{2022} #{tab.label}", else: tab.label
        {{tab.id, {:tab, tab.id}}, label, "No session"}
    end
  end

  @spec session_metadata(pid() | nil) :: {:ok, Session.metadata()} | :error
  defp session_metadata(nil), do: :error

  defp session_metadata(pid) do
    {:ok, Session.metadata(pid)}
  catch
    :exit, _ -> :error
  end

  @spec disk_candidates() :: [Minga.Picker.item()]
  defp disk_candidates do
    SessionStore.list()
    |> Enum.map(fn meta ->
      label = "#{meta.preview}"

      desc =
        "#{meta.model_name} · #{meta.message_count} msgs · $#{Float.round(meta.cost, 4)} · #{meta.timestamp}"

      {{meta.id, :disk}, label, desc}
    end)
  end

  @spec format_label(Session.metadata(), boolean()) :: String.t()
  defp format_label(meta, true) do
    prompt = truncate_prompt(meta.first_prompt)
    "\u{2022} #{prompt}"
  end

  defp format_label(meta, false) do
    truncate_prompt(meta.first_prompt)
  end

  @spec format_desc(Session.metadata()) :: String.t()
  defp format_desc(meta) do
    time = Calendar.strftime(meta.created_at, "%H:%M")
    cost = Float.round(meta.cost, 4)
    "#{meta.model_name} · #{meta.message_count} msgs · $#{cost} · #{time}"
  end

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
