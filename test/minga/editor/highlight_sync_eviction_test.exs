defmodule Minga.Editor.HighlightSyncEvictionTest do
  @moduledoc """
  Tests for LRU eviction of inactive parser buffer trees.
  """
  use ExUnit.Case, async: true

  alias Minga.Editor.HighlightSync
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState

  # Build a minimal state with buffer_ids and last_active_at set up.
  defp base_state do
    %EditorState{
      port_manager: nil,
      workspace: %Minga.Workspace.State{
        viewport: Viewport.new(24, 80),
        vim: VimState.new()
      }
    }
  end

  defp with_buffer_tracking(state, pid, buffer_id, last_active_ms_ago) do
    hl = state.workspace.highlight
    now = System.monotonic_time(:millisecond)

    %{
      state
      | workspace: %{
          state.workspace
          | highlight: %{
              hl
              | buffer_ids: Map.put(hl.buffer_ids, pid, buffer_id),
                reverse_buffer_ids: Map.put(hl.reverse_buffer_ids, buffer_id, pid),
                last_active_at: Map.put(hl.last_active_at, pid, now - last_active_ms_ago),
                next_buffer_id: max(hl.next_buffer_id, buffer_id + 1)
            }
        }
    }
  end

  describe "evict_inactive/2" do
    test "does not evict recently active buffers" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      state = base_state() |> with_buffer_tracking(pid1, 1, 1_000)

      new_state = HighlightSync.evict_inactive(state)

      assert Map.has_key?(new_state.workspace.highlight.buffer_ids, pid1)
      assert Map.has_key?(new_state.workspace.highlight.reverse_buffer_ids, 1)
      assert Map.has_key?(new_state.workspace.highlight.last_active_at, pid1)
    end

    test "evicts buffers inactive longer than TTL" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      # 10 minutes ago (well past the 5-minute default TTL)
      state = base_state() |> with_buffer_tracking(pid1, 1, 10 * 60 * 1_000)

      new_state = HighlightSync.evict_inactive(state)

      refute Map.has_key?(new_state.workspace.highlight.buffer_ids, pid1)
      refute Map.has_key?(new_state.workspace.highlight.reverse_buffer_ids, 1)
      refute Map.has_key?(new_state.workspace.highlight.last_active_at, pid1)
    end

    test "does not evict the active buffer even if stale" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)

      state =
        base_state()
        |> with_buffer_tracking(pid1, 1, 10 * 60 * 1_000)
        |> then(fn s -> put_in(s.workspace.buffers.active, pid1) end)

      new_state = HighlightSync.evict_inactive(state)

      # Active buffer is protected
      assert Map.has_key?(new_state.workspace.highlight.buffer_ids, pid1)
    end

    test "does not evict protected PIDs" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      state = base_state() |> with_buffer_tracking(pid1, 1, 10 * 60 * 1_000)

      new_state = HighlightSync.evict_inactive(state, protected_pids: [pid1])

      assert Map.has_key?(new_state.workspace.highlight.buffer_ids, pid1)
    end

    test "evicts only stale buffers, keeps fresh ones" do
      pid_fresh = spawn(fn -> Process.sleep(:infinity) end)
      pid_stale = spawn(fn -> Process.sleep(:infinity) end)

      state =
        base_state()
        |> with_buffer_tracking(pid_fresh, 1, 1_000)
        |> with_buffer_tracking(pid_stale, 2, 10 * 60 * 1_000)

      new_state = HighlightSync.evict_inactive(state)

      assert Map.has_key?(new_state.workspace.highlight.buffer_ids, pid_fresh)
      refute Map.has_key?(new_state.workspace.highlight.buffer_ids, pid_stale)
    end

    test "returns state unchanged when no buffers are tracked" do
      state = base_state()
      assert HighlightSync.evict_inactive(state) == state
    end

    test "clears highlight cache for evicted buffers" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)

      state =
        base_state()
        |> with_buffer_tracking(pid1, 1, 10 * 60 * 1_000)

      hl = state.workspace.highlight

      state = %{
        state
        | workspace: %{
            state.workspace
            | highlight: %{hl | highlights: Map.put(hl.highlights, pid1, Minga.Highlight.new())}
          }
      }

      new_state = HighlightSync.evict_inactive(state)

      refute Map.has_key?(new_state.workspace.highlight.highlights, pid1)
    end
  end

  describe "touch_active/1" do
    test "sets last_active_at for the active buffer" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)

      state =
        base_state()
        |> then(fn s -> put_in(s.workspace.buffers.active, pid1) end)

      new_state = HighlightSync.touch_active(state)

      assert Map.has_key?(new_state.workspace.highlight.last_active_at, pid1)
      ts = new_state.workspace.highlight.last_active_at[pid1]
      now = System.monotonic_time(:millisecond)
      assert abs(now - ts) < 100
    end

    test "returns state unchanged when no active buffer" do
      state = base_state()
      assert HighlightSync.touch_active(state) == state
    end
  end

  describe "ensure_buffer_id/1" do
    test "assigns a new buffer_id on first call" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)

      state =
        base_state()
        |> then(fn s -> put_in(s.workspace.buffers.active, pid1) end)

      {id, new_state} = HighlightSync.ensure_buffer_id(state)

      assert id == 1
      assert new_state.workspace.highlight.buffer_ids[pid1] == 1
      assert new_state.workspace.highlight.next_buffer_id == 2
    end

    test "returns existing buffer_id on subsequent calls" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)

      state =
        base_state()
        |> then(fn s -> put_in(s.workspace.buffers.active, pid1) end)

      {id1, state} = HighlightSync.ensure_buffer_id(state)
      {id2, _state} = HighlightSync.ensure_buffer_id(state)

      assert id1 == id2
    end

    test "assigns monotonically incrementing IDs for different buffers" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      state =
        base_state()
        |> then(fn s -> put_in(s.workspace.buffers.active, pid1) end)

      {id1, state} = HighlightSync.ensure_buffer_id(state)

      state = %{
        state
        | workspace: %{state.workspace | buffers: %{state.workspace.buffers | active: pid2}}
      }

      {id2, _state} = HighlightSync.ensure_buffer_id(state)

      assert id2 == id1 + 1
    end
  end

  describe "close_buffer/2" do
    test "removes buffer_id mapping and cache" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)

      state =
        base_state()
        |> with_buffer_tracking(pid1, 1, 1_000)

      hl = state.workspace.highlight

      state = %{
        state
        | workspace: %{
            state.workspace
            | highlight: %{hl | highlights: Map.put(hl.highlights, pid1, Minga.Highlight.new())}
          }
      }

      new_state = HighlightSync.close_buffer(state, pid1)

      refute Map.has_key?(new_state.workspace.highlight.buffer_ids, pid1)
      refute Map.has_key?(new_state.workspace.highlight.highlights, pid1)
    end

    test "no-op for unknown buffer PID" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      state = base_state()

      new_state = HighlightSync.close_buffer(state, pid1)
      assert new_state == state
    end
  end
end
