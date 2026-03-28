defmodule Minga.Editor.KeyDispatchToolReentryTest do
  use Minga.Test.EditorCase, async: true

  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode.ToolConfirmState

  describe "tool_confirm re-entry after approval" do
    test "does not crash accessing tool_prompt_queue on EditorState" do
      ctx = start_editor("hello")

      # Set up: tool in queue, enter tool_confirm mode
      :sys.replace_state(ctx.editor, fn state ->
        state =
          EditorState.update_shell_state(state, fn ss ->
            %{ss | tool_prompt_queue: [:pyright], tool_declined: MapSet.new()}
          end)

        ms = %ToolConfirmState{pending: [:pyright], declined: MapSet.new()}
        EditorState.transition_mode(state, :tool_confirm, ms)
      end)

      assert editor_mode(ctx) == :tool_confirm

      # Before the fix, pressing y here crashed with KeyError because
      # key_dispatch.ex accessed result.tool_prompt_queue instead of
      # result.shell_state.tool_prompt_queue. The fix makes this survive.
      send_key_sync(ctx, ?y)

      # The editor process is still alive and responsive
      mode = editor_mode(ctx)
      assert mode in [:tool_confirm, :normal]
    end

    test "returns to normal when queue is empty" do
      ctx = start_editor("hello")

      # Set up: empty queue, enter tool_confirm with a single tool.
      # The queue is empty because in the real flow, tool_prompt_queue
      # is populated externally. Here we test that an empty queue means
      # no re-entry after the mode transitions back to normal.
      :sys.replace_state(ctx.editor, fn state ->
        state =
          EditorState.update_shell_state(state, fn ss ->
            %{ss | tool_prompt_queue: [], tool_declined: MapSet.new()}
          end)

        ms = %ToolConfirmState{pending: [:pyright], declined: MapSet.new()}
        EditorState.transition_mode(state, :tool_confirm, ms)
      end)

      assert editor_mode(ctx) == :tool_confirm

      # Approve the tool. Queue is empty, so no re-entry.
      send_key_sync(ctx, ?y)

      assert editor_mode(ctx) == :normal
    end
  end
end
