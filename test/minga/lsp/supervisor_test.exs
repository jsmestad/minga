defmodule Minga.LSP.SupervisorTest do
  # async: false because mock LSP server spawns OS processes that may not
  # start in time under heavy parallel test load
  use ExUnit.Case, async: false

  alias Minga.Diagnostics
  alias Minga.LSP.Client
  alias Minga.LSP.Supervisor, as: LSPSupervisor
  alias Minga.Test.MockLSPServer

  setup do
    diag_name = :"diag_sup_#{System.unique_integer()}"
    sup_name = :"lsp_sup_#{System.unique_integer()}"

    start_supervised!({Diagnostics, name: diag_name})
    start_supervised!({LSPSupervisor, name: sup_name})

    %{supervisor: sup_name, diag_server: diag_name}
  end

  defp wait_until_ready(client, attempts \\ 500) do
    if attempts <= 0, do: flunk("LSP client did not become ready in time")

    case Client.status(client) do
      :ready -> :ok
      _ -> Process.sleep(10) && wait_until_ready(client, attempts - 1)
    end
  end

  describe "ensure_client/3" do
    test "starts a new client for a server+root pair", %{supervisor: sup} do
      config = MockLSPServer.server_config()
      root = System.tmp_dir!()

      assert {:ok, pid} = LSPSupervisor.ensure_client(sup, config, root)
      assert is_pid(pid)
      assert Process.alive?(pid)
      wait_until_ready(pid)
      assert Client.server_name(pid) == :mock_lsp
    end

    test "returns the same pid for duplicate server+root", %{supervisor: sup} do
      config = MockLSPServer.server_config()
      root = System.tmp_dir!()

      {:ok, pid1} = LSPSupervisor.ensure_client(sup, config, root)
      wait_until_ready(pid1)

      {:ok, pid2} = LSPSupervisor.ensure_client(sup, config, root)
      assert pid1 == pid2
    end

    test "starts separate clients for different roots", %{supervisor: sup} do
      config = MockLSPServer.server_config()
      root1 = System.tmp_dir!()
      root2 = Path.join(System.tmp_dir!(), "other_project")
      File.mkdir_p!(root2)

      {:ok, pid1} = LSPSupervisor.ensure_client(sup, config, root1)
      {:ok, pid2} = LSPSupervisor.ensure_client(sup, config, root2)

      assert pid1 != pid2
    end

    test "returns error for unavailable server", %{supervisor: sup} do
      config = %Minga.LSP.ServerConfig{
        name: :nonexistent,
        command: "definitely_not_a_binary_#{System.unique_integer()}"
      }

      assert {:error, :not_available} = LSPSupervisor.ensure_client(sup, config, "/tmp")
    end
  end

  describe "all_clients/1" do
    test "returns empty list when no clients", %{supervisor: sup} do
      assert LSPSupervisor.all_clients(sup) == []
    end

    test "returns all running client pids", %{supervisor: sup} do
      config = MockLSPServer.server_config()

      {:ok, pid1} = LSPSupervisor.ensure_client(sup, config, System.tmp_dir!())
      wait_until_ready(pid1)

      root2 = Path.join(System.tmp_dir!(), "proj2")
      File.mkdir_p!(root2)
      {:ok, pid2} = LSPSupervisor.ensure_client(sup, config, root2)
      wait_until_ready(pid2)

      clients = LSPSupervisor.all_clients(sup)
      assert length(clients) == 2
      assert pid1 in clients
      assert pid2 in clients
    end
  end
end
