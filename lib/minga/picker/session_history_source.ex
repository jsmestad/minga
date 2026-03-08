defmodule Minga.Picker.SessionHistorySource do
  @moduledoc """
  Picker source for browsing and loading past agent sessions.

  Lists saved sessions from disk, showing timestamp, model, preview
  of the first user message, message count, and cost. Selecting a
  session loads it into the current agent session.
  """

  @behaviour Minga.Picker.Source

  alias Minga.Agent.Session
  alias Minga.Agent.SessionStore

  @impl true
  @spec title() :: String.t()
  def title, do: "Session History"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: false

  @impl true
  @spec candidates(term()) :: [Minga.Picker.item()]
  def candidates(_state) do
    SessionStore.list()
    |> Enum.map(fn meta ->
      label = format_label(meta)
      desc = format_description(meta)
      {meta.id, label, desc}
    end)
  end

  @impl true
  @spec on_select(Minga.Picker.item(), term()) :: term()
  def on_select({session_id, _label, _desc}, state) when is_binary(session_id) do
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

  @spec format_label(SessionStore.session_meta()) :: String.t()
  defp format_label(meta) do
    ts = format_timestamp(meta.timestamp)
    "#{ts}  #{meta.preview}"
  end

  @spec format_description(SessionStore.session_meta()) :: String.t()
  defp format_description(meta) do
    cost_str =
      if meta.cost > 0.0 do
        "$#{Float.round(meta.cost, 3)}"
      else
        ""
      end

    "#{meta.model_name}  #{meta.message_count} msgs  #{cost_str}"
  end

  @spec format_timestamp(String.t()) :: String.t()
  defp format_timestamp(iso_str) do
    case DateTime.from_iso8601(iso_str) do
      {:ok, dt, _offset} ->
        Calendar.strftime(dt, "%b %d %H:%M")

      _ ->
        String.slice(iso_str, 0, 16)
    end
  end
end
