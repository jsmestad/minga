defmodule MingaGhostCursors.Tracker do
  @moduledoc """
  Tracks agent edit positions and manages ghost cursor overlays.

  Subscribes to `:buffer_changed` events, filters for agent-sourced
  edits, and registers overlays via `Minga.Extension.Overlay`. Monitors
  agent session PIDs so overlays are cleaned up when sessions end.
  """

  use GenServer

  alias Minga.Buffer.EditDelta
  alias Minga.Events.BufferChangedEvent
  alias Minga.Extension.AgentAPI
  alias Minga.Extension.Overlay

  @extension_name :minga_ghost_cursors
  @accent_color 0x7C3AED
  @cursor_opacity 102

  @type state :: %{
          monitored: %{optional(pid()) => reference()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(_opts) do
    AgentAPI.subscribe_edits()
    AgentAPI.subscribe()
    {:ok, %{monitored: %{}}}
  end

  @impl true
  def handle_info(
        {:minga_event, :buffer_changed,
         %BufferChangedEvent{
           source: {:agent, session_pid, _tool_call_id},
           delta: %EditDelta{} = delta,
           buffer: buffer_pid
         }},
        state
      ) do
    label = session_label(session_pid)

    Overlay.set(@extension_name, {buffer_pid, session_pid}, buffer_pid,
      position: delta.new_end_position,
      content: label,
      style: %{fg: @accent_color, opacity: @cursor_opacity},
      shape: :cursor_with_label
    )

    state = maybe_monitor(state, session_pid)
    {:noreply, state}
  end

  def handle_info(
        {:minga_event, :buffer_changed, %BufferChangedEvent{}},
        state
      ) do
    {:noreply, state}
  end

  def handle_info(
        {:minga_event, :agent_session_stopped, %{pid: session_pid}},
        state
      ) do
    state = remove_session_overlays(state, session_pid)
    Minga.Events.broadcast(:ghost_cursor_removed, %{session_pid: session_pid})
    {:noreply, state}
  end

  def handle_info({:minga_event, :agent_hook, _payload}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, session_pid, _reason}, state) do
    state = remove_session_overlays(state, session_pid)
    Minga.Events.broadcast(:ghost_cursor_removed, %{session_pid: session_pid})
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @spec session_label(pid()) :: String.t()
  defp session_label(session_pid) do
    case AgentAPI.session_info(session_pid) do
      {:ok, info} -> info.label
      {:error, :not_found} -> "agent"
    end
  catch
    :exit, _ -> "agent"
  end

  @spec maybe_monitor(state(), pid()) :: state()
  defp maybe_monitor(state, session_pid) do
    if Map.has_key?(state.monitored, session_pid) do
      state
    else
      ref = Process.monitor(session_pid)
      put_in(state.monitored[session_pid], ref)
    end
  end

  @spec remove_session_overlays(state(), pid()) :: state()
  defp remove_session_overlays(state, session_pid) do
    Overlay.all()
    |> Enum.filter(fn overlay ->
      overlay.extension == @extension_name and match?({_buf, ^session_pid}, overlay.overlay_id)
    end)
    |> Enum.each(fn overlay ->
      Overlay.remove(@extension_name, overlay.overlay_id)
    end)

    case Map.pop(state.monitored, session_pid) do
      {nil, state} -> state
      {ref, new_monitored} ->
        Process.demonitor(ref, [:flush])
        %{state | monitored: new_monitored}
    end
  end
end
