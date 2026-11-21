defmodule MingaEditor.Commands.LspTest do
  # Uses the global LSP supervisor and buffer-to-client registry.
  use ExUnit.Case, async: false

  alias Minga.LSP.Supervisor, as: LSPSupervisor
  alias Minga.LSP.SyncServer
  alias Minga.Test.LspIsolation
  alias Minga.Test.MockLSPServer
  alias MingaEditor.Commands.Lsp, as: LspCommands

  import MingaEditor.RenderPipeline.TestHelpers

  setup do
    LspIsolation.stop_lsp_clients()
    on_exit(&LspIsolation.stop_lsp_clients/0)
    :ok
  end

  describe "execute/2 :lsp_info" do
    test "shows 'no language servers running' when none active" do
      state = base_state()
      result = LspCommands.execute(state, :lsp_info)
      assert result.shell_runtime.state.notice.message == "No language servers running"
    end
  end

  describe "execute/2 :lsp_restart" do
    test "shows 'no active buffer' when buffer is nil" do
      state = base_state()

      state = %{
        state
        | workspace: %{state.workspace | buffers: %{state.workspace.buffers | active: nil}}
      }

      result = LspCommands.execute(state, :lsp_restart)
      assert result.shell_runtime.state.notice.message == "No active buffer"
    end

    test "shows 'no LSP server' when no clients attached" do
      state = base_state()
      result = LspCommands.execute(state, :lsp_restart)
      assert result.shell_runtime.state.notice.message == "No LSP server for this buffer"
    end
  end

  describe "execute/2 :lsp_stop" do
    test "shows 'no active buffer' when buffer is nil" do
      state = base_state()

      state = %{
        state
        | workspace: %{state.workspace | buffers: %{state.workspace.buffers | active: nil}}
      }

      result = LspCommands.execute(state, :lsp_stop)
      assert result.shell_runtime.state.notice.message == "No active buffer"
    end

    test "shows 'no LSP server' when no clients attached" do
      state = base_state()
      result = LspCommands.execute(state, :lsp_stop)
      assert result.shell_runtime.state.notice.message == "No LSP server for this buffer"
    end

    @tag :heavy
    @tag :tmp_dir
    test "stops only the attached root and skips a dead client", %{tmp_dir: root} do
      other_root = Path.join(root, "other")
      File.mkdir!(other_root)
      config = MockLSPServer.server_config()
      {:ok, target} = LSPSupervisor.ensure_client(config, root)
      {:ok, other} = LSPSupervisor.ensure_client(config, other_root)
      {dead, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^dead, :normal}

      state = base_state()
      buffer = state.workspace.buffers.active
      SyncServer.put_clients(buffer, [dead, target])
      on_exit(fn -> SyncServer.remove_buffer(buffer) end)

      stopped = LspCommands.execute(state, :lsp_stop)

      assert stopped.shell_runtime.state.notice.message == "Stopped mock_lsp"
      assert LSPSupervisor.find_client({:mock_lsp, root}) == :not_found
      assert LSPSupervisor.find_client({:mock_lsp, other_root}) == {:ok, other}
    end
  end

  describe "execute/2 :lsp_start" do
    test "shows 'no active buffer' when buffer is nil" do
      state = base_state()

      state = %{
        state
        | workspace: %{state.workspace | buffers: %{state.workspace.buffers | active: nil}}
      }

      result = LspCommands.execute(state, :lsp_start)
      assert result.shell_runtime.state.notice.message == "No active buffer"
    end

    test "shows 'no LSP server available' for unsupported filetype" do
      state = base_state(filetype: :unknown)
      result = LspCommands.execute(state, :lsp_start)
      # The test buffer has an unsupported filetype with no configured LSP server
      assert String.contains?(
               result.shell_runtime.state.notice.message,
               "No LSP server available"
             )
    end
  end
end
