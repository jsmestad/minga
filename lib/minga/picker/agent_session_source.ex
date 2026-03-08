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
  alias Minga.Editor.State.Agent, as: AgentState

  @impl true
  @spec title() :: String.t()
  def title, do: "Sessions"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: false

  @impl true
  @spec candidates(term()) :: [Minga.Picker.item()]
  def candidates(%{agent: %AgentState{} = agent}) do
    live = live_candidates(agent)
    disk = disk_candidates(agent)

    # Merge: live sessions take priority over disk entries with the same id
    live_ids = MapSet.new(live, fn {{id, _}, _, _} -> id end)

    merged =
      live ++
        Enum.reject(disk, fn {{id, _}, _, _} -> MapSet.member?(live_ids, id) end)

    # Sort by most recent first (already sorted within each source)
    merged
  end

  def candidates(_state), do: []

  @impl true
  @spec on_select(Minga.Picker.item(), term()) :: term()
  def on_select({{_id, {:live, pid}}, _label, _desc}, state) do
    Minga.Editor.Commands.Agent.switch_to_session(state, pid)
  end

  def on_select({{session_id, :disk}, _label, _desc}, state) do
    # Load a persisted session into the current session process
    case state.agent.session do
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

  @spec live_candidates(AgentState.t()) :: [Minga.Picker.item()]
  defp live_candidates(agent) do
    pids = AgentState.all_sessions(agent)

    pids
    |> Enum.map(fn pid ->
      try do
        meta = Session.metadata(pid)
        {pid, meta}
      catch
        :exit, _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_, meta} -> meta.created_at end, {:desc, DateTime})
    |> Enum.map(fn {pid, meta} ->
      is_active = pid == agent.session
      label = format_label(meta, is_active)
      desc = format_desc(meta)
      {{meta.id, {:live, pid}}, label, desc}
    end)
  end

  @spec disk_candidates(AgentState.t()) :: [Minga.Picker.item()]
  defp disk_candidates(_agent) do
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
    "● #{prompt}"
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
