defmodule Minga.Editor.Commands.LspTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.Commands.Lsp, as: LspCommands

  import Minga.Editor.RenderPipeline.TestHelpers

  describe "execute/2 :lsp_info" do
    test "shows 'no language servers running' when none active" do
      state = base_state()
      result = LspCommands.execute(state, :lsp_info)
      assert result.status_msg == "No language servers running"
    end
  end

  describe "execute/2 :lsp_restart" do
    test "shows 'no active buffer' when buffer is nil" do
      state = base_state()
      state = %{state | workspace: %{state.workspace | buffers: %{state.workspace.buffers | active: nil}}}
      result = LspCommands.execute(state, :lsp_restart)
      assert result.status_msg == "No active buffer"
    end

    test "shows 'no LSP server' when no clients attached" do
      state = base_state()
      result = LspCommands.execute(state, :lsp_restart)
      assert result.status_msg == "No LSP server for this buffer"
    end
  end

  describe "execute/2 :lsp_stop" do
    test "shows 'no active buffer' when buffer is nil" do
      state = base_state()
      state = %{state | workspace: %{state.workspace | buffers: %{state.workspace.buffers | active: nil}}}
      result = LspCommands.execute(state, :lsp_stop)
      assert result.status_msg == "No active buffer"
    end

    test "shows 'no LSP server' when no clients attached" do
      state = base_state()
      result = LspCommands.execute(state, :lsp_stop)
      assert result.status_msg == "No LSP server for this buffer"
    end
  end

  describe "execute/2 :lsp_start" do
    test "shows 'no active buffer' when buffer is nil" do
      state = base_state()
      state = %{state | workspace: %{state.workspace | buffers: %{state.workspace.buffers | active: nil}}}
      result = LspCommands.execute(state, :lsp_start)
      assert result.status_msg == "No active buffer"
    end

    test "shows 'no LSP server available' for unsupported filetype" do
      state = base_state()
      result = LspCommands.execute(state, :lsp_start)
      # The test buffer has :text filetype with no configured LSP server
      assert String.contains?(result.status_msg, "No LSP server available")
    end
  end
end
