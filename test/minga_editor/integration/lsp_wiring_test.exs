defmodule Minga.Integration.LspWiringTest do
  @moduledoc """
  Thin Editor GenServer smoke tests for LSP trigger and response routing.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Events
  alias MingaEditor.State.LSP

  describe "LSP no-op triggers" do
    test "deferred and save triggers are safe without an LSP client" do
      ctx = start_editor("defmodule Foo do\n  def bar, do: :ok\nend")

      send(ctx.editor, :request_code_lens_and_inlay_hints)
      assert sync_editor(ctx) == :normal

      save_event = %Events.BufferEvent{buffer: ctx.buffer, path: "/tmp/test.ex"}
      send(ctx.editor, {:minga_event, :buffer_saved, save_event})
      assert sync_editor(ctx) == :normal
    end

    test "deferred trigger is safe without an active buffer" do
      ctx = start_editor("hello")

      :sys.replace_state(ctx.editor, fn state ->
        put_in(state.workspace.buffers.active, nil)
      end)

      send(ctx.editor, :request_code_lens_and_inlay_hints)

      assert sync_editor(ctx) == :normal
    end
  end

  describe "mouse hover LSP response routing" do
    test "tuple-keyed hover response creates a popup at the mouse position" do
      ctx = start_editor("defmodule Foo do\n  def bar, do: :ok\nend")
      ref = make_ref()

      :sys.replace_state(ctx.editor, fn state ->
        put_in(state.workspace.lsp_pending[ref], {:hover_mouse, 5, 20})
      end)

      hover_result =
        {:ok, %{"contents" => %{"kind" => "plaintext", "value" => "fn bar() :: :ok"}}}

      send(ctx.editor, {:lsp_response, ref, hover_result})

      state =
        wait_until(ctx, fn state -> state.shell_state.hover_popup != nil end,
          max_attempts: 10,
          interval_ms: 10,
          message: "hover popup should be created from {:hover_mouse, ...} response"
        )

      assert state.shell_state.hover_popup.anchor_row == 5
      assert state.shell_state.hover_popup.anchor_col == 20
    end
  end

  describe "selection range cleanup on visual mode exit" do
    test "leaving visual mode clears selection range state" do
      ctx = start_editor("hello world\nsecond line")

      :sys.replace_state(ctx.editor, fn state ->
        %{
          state
          | lsp:
              state.lsp |> LSP.set_selection_ranges([selection_range()]) |> LSP.expand_selection()
        }
      end)

      send_keys_sync(ctx, "v")
      assert editor_mode(ctx) == :visual

      send_keys_sync(ctx, "<Esc>")
      assert editor_mode(ctx) == :normal

      state =
        wait_until(
          ctx,
          fn state ->
            state.lsp.selection_ranges == nil and state.lsp.selection_range_index == 0
          end,
          max_attempts: 5,
          interval_ms: 10,
          message: "selection range state should be cleared after visual mode exit"
        )

      assert state.lsp.selection_ranges == nil
      assert state.lsp.selection_range_index == 0
    end
  end

  defp sync_editor(ctx), do: GenServer.call(ctx.editor, :api_mode)

  defp selection_range do
    %{"range" => %{"start" => %{"line" => 0}, "end" => %{"line" => 1}}}
  end
end
