defmodule Minga.Extensions.GhostCursorsTrackerTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.EditDelta
  alias Minga.Events.BufferChangedEvent
  alias Minga.Extension.Overlay
  alias MingaGhostCursors.Tracker

  setup do
    tracker_name = :"tracker_#{System.unique_integer([:positive])}"
    tracker = start_supervised!({Tracker, name: tracker_name}, id: tracker_name)

    on_exit(fn -> Overlay.remove_all(:minga_ghost_cursors) end)

    %{tracker: tracker}
  end

  defp agent_edit_event(buffer_pid, session_pid, position) do
    {:minga_event, :buffer_changed,
     %BufferChangedEvent{
       buffer: buffer_pid,
       source: {:agent, session_pid, "tool_call_1"},
       delta: %EditDelta{
         start_byte: 0,
         old_end_byte: 0,
         new_end_byte: 5,
         start_position: {0, 0},
         old_end_position: {0, 0},
         new_end_position: position,
         inserted_text: "hello"
       },
       version: 1
     }}
  end

  defp spawn_waiting do
    spawn(fn -> receive do: (:stop -> :ok) end)
  end

  describe "buffer_changed events" do
    test "registers overlay for agent-sourced edits", %{tracker: tracker} do
      buffer_pid = spawn_waiting()
      session_pid = spawn_waiting()

      send(tracker, agent_edit_event(buffer_pid, session_pid, {5, 10}))
      wait_for_processing(tracker)

      overlays = Overlay.all()
      assert length(overlays) == 1

      [overlay] = overlays
      assert overlay.extension == :minga_ghost_cursors
      assert overlay.overlay_id == {buffer_pid, session_pid}
      assert overlay.buffer == buffer_pid
      assert overlay.position == {5, 10}
      assert overlay.shape == :cursor_with_label
      assert overlay.style == %{fg: 0x7C3AED, opacity: 102}

      Process.exit(buffer_pid, :kill)
      Process.exit(session_pid, :kill)
    end

    test "updates overlay position on subsequent edits", %{tracker: tracker} do
      buffer_pid = spawn_waiting()
      session_pid = spawn_waiting()

      send(tracker, agent_edit_event(buffer_pid, session_pid, {5, 10}))
      wait_for_processing(tracker)

      send(tracker, agent_edit_event(buffer_pid, session_pid, {12, 3}))
      wait_for_processing(tracker)

      overlays = Overlay.all()
      assert length(overlays) == 1
      assert hd(overlays).position == {12, 3}

      Process.exit(buffer_pid, :kill)
      Process.exit(session_pid, :kill)
    end

    test "ignores non-agent edits", %{tracker: tracker} do
      event =
        {:minga_event, :buffer_changed,
         %BufferChangedEvent{
           buffer: self(),
           source: :user,
           delta: nil,
           version: 1
         }}

      send(tracker, event)
      wait_for_processing(tracker)

      assert Overlay.all() == []
    end

    test "ignores agent edits without a delta", %{tracker: tracker} do
      session_pid = spawn_waiting()

      event =
        {:minga_event, :buffer_changed,
         %BufferChangedEvent{
           buffer: self(),
           source: {:agent, session_pid, "tool_1"},
           delta: nil,
           version: 1
         }}

      send(tracker, event)
      wait_for_processing(tracker)

      assert Overlay.all() == []

      Process.exit(session_pid, :kill)
    end

    test "tracks overlays per buffer per session", %{tracker: tracker} do
      buf1 = spawn_waiting()
      buf2 = spawn_waiting()
      session = spawn_waiting()

      send(tracker, agent_edit_event(buf1, session, {1, 0}))
      send(tracker, agent_edit_event(buf2, session, {2, 0}))
      wait_for_processing(tracker)

      assert length(Overlay.all()) == 2

      Process.exit(buf1, :kill)
      Process.exit(buf2, :kill)
      Process.exit(session, :kill)
    end
  end

  describe "session cleanup" do
    test "removes overlays when session PID exits", %{tracker: tracker} do
      buffer_pid = spawn_waiting()
      session_pid = spawn_waiting()

      Minga.Events.subscribe(:ghost_cursor_removed)

      send(tracker, agent_edit_event(buffer_pid, session_pid, {5, 10}))
      wait_for_processing(tracker)

      assert length(Overlay.all()) == 1

      Process.exit(session_pid, :kill)
      assert_receive {:minga_event, :ghost_cursor_removed, %{session_pid: ^session_pid}}

      assert Overlay.all() == []

      Process.exit(buffer_pid, :kill)
    end

    test "removes overlays on agent_session_stopped event", %{tracker: tracker} do
      buffer_pid = spawn_waiting()
      session_pid = spawn_waiting()

      Minga.Events.subscribe(:ghost_cursor_removed)

      send(tracker, agent_edit_event(buffer_pid, session_pid, {5, 10}))
      wait_for_processing(tracker)

      send(tracker, {:minga_event, :agent_session_stopped, %{pid: session_pid}})
      assert_receive {:minga_event, :ghost_cursor_removed, %{session_pid: ^session_pid}}

      assert Overlay.all() == []

      Process.exit(buffer_pid, :kill)
      Process.exit(session_pid, :kill)
    end

    test "only removes overlays for the stopped session", %{tracker: tracker} do
      buf = spawn_waiting()
      session1 = spawn_waiting()
      session2 = spawn_waiting()

      Minga.Events.subscribe(:ghost_cursor_removed)

      send(tracker, agent_edit_event(buf, session1, {1, 0}))
      send(tracker, agent_edit_event(buf, session2, {2, 0}))
      wait_for_processing(tracker)

      assert length(Overlay.all()) == 2

      send(tracker, {:minga_event, :agent_session_stopped, %{pid: session1}})
      assert_receive {:minga_event, :ghost_cursor_removed, %{session_pid: ^session1}}

      overlays = Overlay.all()
      assert length(overlays) == 1
      assert hd(overlays).overlay_id == {buf, session2}

      Process.exit(buf, :kill)
      Process.exit(session1, :kill)
      Process.exit(session2, :kill)
    end
  end

  defp wait_for_processing(tracker) do
    :sys.get_state(tracker)
  end
end
