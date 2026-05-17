defmodule MingaEditor.Workspace.StateTest do
  @moduledoc """
  Tests for pure workspace state transitions.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Workspace.State, as: WorkspaceState
  alias MingaEditor.Window

  import MingaEditor.RenderPipeline.TestHelpers

  describe "sync_active_window_buffer/1" do
    test "clears document symbols when the active window changes buffers" do
      state = base_state(content: "defmodule First do\nend\n")
      first_buf = state.workspace.buffers.active
      {:ok, second_buf} = BufferProcess.start_link(content: "plain text")
      symbols = [%Minga.Language.Symbol{kind: :module, name: "First", range: {0, 0, 1, 3}}]
      win_id = state.workspace.windows.active

      workspace =
        state.workspace
        |> WorkspaceState.update_window(win_id, &Window.set_document_symbols(&1, symbols))
        |> put_in([Access.key!(:buffers)], %{
          state.workspace.buffers
          | active: second_buf,
            list: [first_buf, second_buf],
            active_index: 1
        })

      synced = WorkspaceState.sync_active_window_buffer(workspace)
      window = Map.fetch!(synced.windows.map, win_id)

      assert window.buffer == second_buf
      assert window.document_symbols == []
    end
  end
end
