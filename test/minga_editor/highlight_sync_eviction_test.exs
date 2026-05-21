defmodule MingaEditor.HighlightSyncEvictionTest do
  @moduledoc """
  Tests for parser-buffer highlight tracking and eviction.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.HighlightSync
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

  describe "evict_inactive/2" do
    test "evicts stale buffers while keeping recently active buffers" do
      fresh = tracked_pid()
      stale = tracked_pid()

      state =
        base_state()
        |> with_buffer_tracking(fresh, 1, 1_000)
        |> with_buffer_tracking(stale, 2, 10 * 60 * 1_000)

      new_state = HighlightSync.evict_inactive(state)

      assert tracked?(new_state, fresh, 1)
      refute tracked?(new_state, stale, 2)
    end

    test "keeps active and explicitly protected stale buffers" do
      active = tracked_pid()
      protected = tracked_pid()

      state =
        base_state()
        |> with_buffer_tracking(active, 1, 10 * 60 * 1_000)
        |> with_buffer_tracking(protected, 2, 10 * 60 * 1_000)
        |> put_active(active)

      new_state = HighlightSync.evict_inactive(state, protected_pids: [protected])

      assert tracked?(new_state, active, 1)
      assert tracked?(new_state, protected, 2)
    end

    test "returns state unchanged when no buffers are tracked" do
      state = base_state()

      assert HighlightSync.evict_inactive(state) == state
    end

    test "clears highlight cache for evicted buffers" do
      stale = tracked_pid()

      state =
        base_state()
        |> with_buffer_tracking(stale, 1, 10 * 60 * 1_000)
        |> put_highlight_cache(stale)

      new_state = HighlightSync.evict_inactive(state)

      refute Map.has_key?(new_state.workspace.highlight.highlights, stale)
    end
  end

  describe "touch_active/1" do
    test "sets last_active_at for the active buffer" do
      active = tracked_pid()
      state = base_state() |> put_active(active)

      new_state = HighlightSync.touch_active(state)

      assert Map.has_key?(new_state.workspace.highlight.last_active_at, active)
      ts = new_state.workspace.highlight.last_active_at[active]
      now = System.monotonic_time(:millisecond)
      assert abs(now - ts) < 100
    end

    test "returns state unchanged when no active buffer" do
      state = base_state()

      assert HighlightSync.touch_active(state) == state
    end
  end

  describe "ensure_buffer_id/1" do
    test "assigns and reuses buffer IDs" do
      active = tracked_pid()
      state = base_state() |> put_active(active)

      {id1, state} = HighlightSync.ensure_buffer_id(state)
      {id2, state} = HighlightSync.ensure_buffer_id(state)

      assert id1 == 1
      assert id2 == id1
      assert state.workspace.highlight.buffer_ids[active] == 1
      assert state.workspace.highlight.next_buffer_id == 2
    end

    test "assigns monotonically incrementing IDs for different buffers" do
      first = tracked_pid()
      second = tracked_pid()
      state = base_state() |> put_active(first)

      {id1, state} = HighlightSync.ensure_buffer_id(state)
      {id2, _state} = state |> put_active(second) |> HighlightSync.ensure_buffer_id()

      assert id2 == id1 + 1
    end
  end

  describe "close_buffer/2" do
    test "removes buffer ID mapping and cache" do
      pid = tracked_pid()

      state =
        base_state()
        |> with_buffer_tracking(pid, 1, 1_000)
        |> put_highlight_cache(pid)

      new_state = HighlightSync.close_buffer(state, pid)

      refute Map.has_key?(new_state.workspace.highlight.buffer_ids, pid)
      refute Map.has_key?(new_state.workspace.highlight.highlights, pid)
    end

    test "is a no-op for unknown buffer PIDs" do
      assert HighlightSync.close_buffer(base_state(), tracked_pid()) == base_state()
    end
  end

  defp base_state do
    %EditorState{
      port_manager: nil,
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        editing: VimState.new()
      }
    }
  end

  defp tracked_pid do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(pid), do: send(pid, :stop) end)
    pid
  end

  defp with_buffer_tracking(state, pid, buffer_id, last_active_ms_ago) do
    hl = state.workspace.highlight
    now = System.monotonic_time(:millisecond)

    put_highlight(state, %{
      hl
      | buffer_ids: Map.put(hl.buffer_ids, pid, buffer_id),
        reverse_buffer_ids: Map.put(hl.reverse_buffer_ids, buffer_id, pid),
        last_active_at: Map.put(hl.last_active_at, pid, now - last_active_ms_ago),
        next_buffer_id: max(hl.next_buffer_id, buffer_id + 1)
    })
  end

  defp put_active(state, pid) do
    put_in(state.workspace.buffers.active, pid)
  end

  defp put_highlight_cache(state, pid) do
    hl = state.workspace.highlight

    put_highlight(state, %{
      hl
      | highlights: Map.put(hl.highlights, pid, MingaEditor.UI.Highlight.new())
    })
  end

  defp put_highlight(state, highlight) do
    put_in(state.workspace.highlight, highlight)
  end

  defp tracked?(state, pid, buffer_id) do
    Map.has_key?(state.workspace.highlight.buffer_ids, pid) and
      Map.has_key?(state.workspace.highlight.reverse_buffer_ids, buffer_id) and
      Map.has_key?(state.workspace.highlight.last_active_at, pid)
  end
end
