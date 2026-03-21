defmodule Minga.Integration.LspWiringTest do
  @moduledoc """
  Integration tests for LSP feature wiring in the Editor GenServer.

  These tests verify that trigger messages (timer, save event, scroll)
  route correctly through the Editor without crashing, and that LSP
  responses with complex keys (tuple dispatch) are handled properly.

  None of these tests require a real or mock LSP server. They test at
  the GenServer message boundary: send a trigger, sync with
  `:sys.get_state/1`, assert the editor is alive and state changed.
  """
  use Minga.Test.EditorCase, async: true

  alias Minga.Events

  # 50-line buffer for scroll tests
  @scroll_content Enum.map_join(1..50, "\n", &"line #{&1}")

  # ── Code lens / inlay hints on open ────────────────────────────────────────

  describe "code lens and inlay hints on buffer open" do
    test "timer message is handled without crash when no LSP client" do
      ctx = start_editor("defmodule Foo do\n  def bar, do: :ok\nend")

      # Simulate the deferred timer firing (normally 800ms after open).
      # With no LSP client registered, code_lens/inlay_hints no-op gracefully.
      send(ctx.editor, :request_code_lens_and_inlay_hints)

      # Sync: if the handler crashed, get_state would raise.
      state = :sys.get_state(ctx.editor)
      assert state.vim.mode == :normal
    end

    test "timer message with no active buffer is gracefully handled" do
      ctx = start_editor("hello")

      # Remove the active buffer to simulate the edge case
      :sys.replace_state(ctx.editor, fn state ->
        put_in(state.buffers.active, nil)
      end)

      # Should not crash even with no active buffer
      send(ctx.editor, :request_code_lens_and_inlay_hints)
      state = :sys.get_state(ctx.editor)
      assert is_map(state)
    end
  end

  # ── Code lens / inlay hints on save ────────────────────────────────────────

  describe "code lens and inlay hints on save" do
    test "save event triggers lens and hint requests without crash" do
      ctx = start_editor("hello world")

      # Send a buffer_saved event (the Editor subscribes to this in init)
      save_event = %Events.BufferEvent{buffer: ctx.buffer, path: "/tmp/test.ex"}
      send(ctx.editor, {:minga_event, :buffer_saved, save_event})

      # Sync and verify the editor is still alive
      state = :sys.get_state(ctx.editor)
      assert state.vim.mode == :normal
    end
  end

  # ── Inlay hints on scroll ──────────────────────────────────────────────────

  describe "inlay hints on scroll" do
    test "scroll wheel schedules debounced inlay hint refresh" do
      ctx = start_editor(@scroll_content)

      # Record initial viewport top
      state_before = :sys.get_state(ctx.editor)
      initial_vp_top = state_before.last_inlay_viewport_top

      # Scroll down with the mouse wheel
      send_mouse(ctx, 10, 10, :wheel_down)

      # The viewport should have moved, scheduling an inlay hint timer
      state = :sys.get_state(ctx.editor)

      assert state.inlay_hint_debounce_timer != nil,
             "scroll wheel should schedule inlay hint debounce timer"

      assert state.last_inlay_viewport_top != initial_vp_top,
             "viewport top should have changed after scroll"

      # Clean up: cancel the timer to avoid late messages
      Process.cancel_timer(state.inlay_hint_debounce_timer)
    end

    test "inlay hint debounce timer fires and clears itself" do
      ctx = start_editor(@scroll_content)

      # Scroll to trigger the debounce timer
      send_mouse(ctx, 10, 10, :wheel_down)

      state = :sys.get_state(ctx.editor)
      assert state.inlay_hint_debounce_timer != nil

      # Wait for the debounce timer to fire (200ms + margin)
      state =
        wait_until(ctx, fn s -> s.inlay_hint_debounce_timer == nil end,
          max_attempts: 30,
          interval_ms: 20,
          message: "inlay hint debounce timer should have fired and cleared itself"
        )

      assert state.inlay_hint_debounce_timer == nil
    end
  end

  # ── Mouse hover LSP response routing ───────────────────────────────────────

  describe "mouse hover LSP response routing" do
    test "response with {:hover_mouse, row, col} creates popup at mouse position" do
      ctx = start_editor("defmodule Foo do\n  def bar, do: :ok\nend")

      # Inject a fake pending LSP request with a {:hover_mouse, row, col} key
      ref = make_ref()

      :sys.replace_state(ctx.editor, fn state ->
        %{state | lsp_pending: Map.put(state.lsp_pending, ref, {:hover_mouse, 5, 20})}
      end)

      # Send an LSP response for that ref
      hover_result =
        {:ok, %{"contents" => %{"kind" => "plaintext", "value" => "fn bar() :: :ok"}}}

      send(ctx.editor, {:lsp_response, ref, hover_result})

      # Wait for the response to be processed and render to complete
      state =
        wait_until(ctx, fn s -> s.hover_popup != nil end,
          max_attempts: 10,
          interval_ms: 10,
          message: "hover popup should be created from {:hover_mouse, ...} response"
        )

      assert state.hover_popup != nil
      assert state.hover_popup.anchor_row == 5
      assert state.hover_popup.anchor_col == 20
    end
  end

  # ── Selection range cleanup on mode exit ───────────────────────────────────

  describe "selection range cleanup on visual mode exit" do
    test "leaving visual mode clears selection range state" do
      ctx = start_editor("hello world\nsecond line")

      # Inject fake selection range state
      :sys.replace_state(ctx.editor, fn state ->
        %{
          state
          | selection_ranges: [
              %{"range" => %{"start" => %{"line" => 0}, "end" => %{"line" => 1}}}
            ],
            selection_range_index: 1
        }
      end)

      # Enter visual mode then exit
      send_keys(ctx, "v")
      assert editor_mode(ctx) == :visual

      send_keys(ctx, "<Esc>")
      assert editor_mode(ctx) == :normal

      # Selection range state should be cleared
      state = :sys.get_state(ctx.editor)
      assert state.selection_ranges == nil
      assert state.selection_range_index == 0
    end
  end
end
