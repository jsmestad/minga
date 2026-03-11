defmodule Minga.Surface.ContractTest do
  @moduledoc """
  Shared contract tests for Surface behaviour implementations.

  Verifies that every surface implementation returns correct types
  from all callbacks. Each surface module includes this test via
  `describe` blocks that call the shared assertions.
  """

  use ExUnit.Case, async: true

  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Mode
  alias Minga.Surface.BufferView
  alias Minga.Surface.BufferView.Bridge
  alias Minga.Surface.BufferView.State, as: BVState
  alias Minga.Surface.BufferView.State.VimState
  alias Minga.Theme

  # ── Helper: build a minimal BufferView state ──────────────────────────────

  defp build_bv_state do
    %BVState{
      viewport: Viewport.new(24, 80),
      editing: %VimState{
        mode: :normal,
        mode_state: Mode.initial_state()
      }
    }
  end

  # ── Contract: scope/0 ────────────────────────────────────────────────────

  describe "BufferView.scope/0" do
    test "returns an atom" do
      assert is_atom(BufferView.scope())
    end

    test "returns :editor" do
      assert BufferView.scope() == :editor
    end
  end

  # ── Contract: handle_key/3 ──────────────────────────────────────────────

  describe "BufferView.handle_key/3" do
    test "returns a {state, effects} tuple" do
      bv = build_bv_state()
      {new_state, effects} = BufferView.handle_key(bv, ?j, 0)

      assert %BVState{} = new_state
      assert is_list(effects)
    end

    test "effects list contains only valid effect types" do
      bv = build_bv_state()
      {_state, effects} = BufferView.handle_key(bv, ?j, 0)

      for effect <- effects do
        assert valid_effect?(effect),
               "Expected a valid effect, got: #{inspect(effect)}"
      end
    end
  end

  # ── Contract: handle_mouse/7 ────────────────────────────────────────────

  describe "BufferView.handle_mouse/7" do
    test "returns a {state, effects} tuple" do
      bv = build_bv_state()
      {new_state, effects} = BufferView.handle_mouse(bv, 5, 10, :left, 0, :press, 1)

      assert %BVState{} = new_state
      assert is_list(effects)
    end
  end

  # ── Contract: render/2 ─────────────────────────────────────────────────

  describe "BufferView.render/2" do
    test "returns a {state, draws} tuple" do
      bv = build_bv_state()
      rect = {0, 0, 80, 24}
      {new_state, draws} = BufferView.render(bv, rect)

      assert %BVState{} = new_state
      assert is_list(draws)
    end
  end

  # ── Contract: handle_event/2 ────────────────────────────────────────────

  describe "BufferView.handle_event/2" do
    test "returns a {state, effects} tuple for unknown events" do
      bv = build_bv_state()
      {new_state, effects} = BufferView.handle_event(bv, {:unknown_event, :data})

      assert %BVState{} = new_state
      assert is_list(effects)
    end
  end

  # ── Contract: cursor/1 ─────────────────────────────────────────────────

  describe "BufferView.cursor/1" do
    test "returns {row, col, shape} tuple" do
      bv = build_bv_state()
      {row, col, shape} = BufferView.cursor(bv)

      assert is_integer(row) and row >= 0
      assert is_integer(col) and col >= 0
      assert is_atom(shape)
    end

    test "cursor shape is :block in normal mode" do
      bv = build_bv_state()
      {_row, _col, shape} = BufferView.cursor(bv)
      assert shape == :block
    end

    test "cursor shape is :beam in insert mode" do
      bv = %{
        build_bv_state()
        | editing: %VimState{
            mode: :insert,
            mode_state: Mode.initial_state()
          }
      }

      {_row, _col, shape} = BufferView.cursor(bv)
      assert shape == :beam
    end

    test "cursor shape is :underline in replace mode" do
      bv = %{
        build_bv_state()
        | editing: %VimState{
            mode: :replace,
            mode_state: Mode.initial_state()
          }
      }

      {_row, _col, shape} = BufferView.cursor(bv)
      assert shape == :underline
    end
  end

  # ── Contract: activate/1 and deactivate/1 ──────────────────────────────

  describe "BufferView.activate/1 and deactivate/1" do
    test "round-trip preserves state" do
      bv = build_bv_state()

      deactivated = BufferView.deactivate(bv)
      reactivated = BufferView.activate(deactivated)

      assert reactivated == bv
    end

    test "activate returns a BufferView.State" do
      bv = build_bv_state()
      assert %BVState{} = BufferView.activate(bv)
    end

    test "deactivate returns a BufferView.State" do
      bv = build_bv_state()
      assert %BVState{} = BufferView.deactivate(bv)
    end
  end

  # ── Contract: bridge round-trip ─────────────────────────────────────────

  describe "Bridge round-trip" do
    test "from_editor_state produces a valid BufferView.State" do
      # Build a minimal EditorState
      es = %EditorState{
        port_manager: nil,
        viewport: Viewport.new(24, 80),
        mode: :normal,
        mode_state: Mode.initial_state()
      }

      bv = Bridge.from_editor_state(es)
      assert %BVState{} = bv
      assert %VimState{mode: :normal} = bv.editing
    end

    test "to_editor_state writes back all BufferView fields" do
      es = %EditorState{
        port_manager: nil,
        viewport: Viewport.new(24, 80),
        mode: :normal,
        mode_state: Mode.initial_state()
      }

      bv = Bridge.from_editor_state(es)

      # Mutate a field in the BufferView state
      bv = %{bv | editing: %{bv.editing | mode: :insert}}

      es2 = Bridge.to_editor_state(es, bv)

      # The mode should have been written back
      assert es2.mode == :insert
    end

    test "round-trip preserves all buffer-view fields" do
      es = %EditorState{
        port_manager: nil,
        viewport: Viewport.new(24, 80),
        mode: :normal,
        mode_state: Mode.initial_state()
      }

      bv = Bridge.from_editor_state(es)
      es2 = Bridge.to_editor_state(es, bv)

      # All buffer-view fields should be unchanged
      assert es2.mode == es.mode
      assert es2.mode_state == es.mode_state
      assert es2.buffers == es.buffers
      assert es2.windows == es.windows
      assert es2.viewport == es.viewport
      assert es2.search == es.search
      assert es2.marks == es.marks
      assert es2.reg == es.reg
    end

    test "round-trip does not modify non-buffer-view fields" do
      theme = Theme.get!(:doom_one)

      es = %EditorState{
        port_manager: nil,
        viewport: Viewport.new(24, 80),
        mode: :normal,
        mode_state: Mode.initial_state(),
        theme: theme,
        status_msg: "hello"
      }

      bv = Bridge.from_editor_state(es)
      es2 = Bridge.to_editor_state(es, bv)

      # Non-buffer-view fields should be untouched
      assert es2.theme == theme
      assert es2.status_msg == "hello"
      assert es2.port_manager == nil
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp valid_effect?(:render), do: true
  defp valid_effect?({:open_file, path}) when is_binary(path), do: true
  defp valid_effect?({:switch_buffer, pid}) when is_pid(pid), do: true
  defp valid_effect?({:set_status, msg}) when is_binary(msg), do: true
  defp valid_effect?({:push_overlay, mod}) when is_atom(mod), do: true
  defp valid_effect?({:pop_overlay, mod}) when is_atom(mod), do: true
  defp valid_effect?(_), do: false
end
