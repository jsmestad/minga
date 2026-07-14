defmodule MingaAgent.Tools.LspCodeActionsTest do
  # async: false because this test registers a fake client in the shared SyncServer singleton.
  use ExUnit.Case, async: false

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.LSP.SyncServer
  alias MingaAgent.Tools.LspCodeActions

  setup do
    SyncServer.clear_registry()
    on_exit(&SyncServer.clear_registry/0)
    :ok
  end

  describe "execute/3 without LSP client" do
    test "returns error when no buffer exists" do
      {:error, result} = LspCodeActions.execute("/nonexistent/file.ex", 10)
      assert result =~ "No buffer open"
      assert result =~ "file must be open"
    end
  end

  describe "execute/3 with edits" do
    @tag :tmp_dir
    test "returns an error when the target buffer is read-only", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "read_only.ex")
      File.write!(path, "old_name\n")

      buffer =
        start_supervised!(
          {BufferProcess, file_path: path, content: "old_name\n", read_only: true}
        )

      action = %{
        "title" => "Replace name",
        "edit" => workspace_edit(path, "new_name")
      }

      client = start_fake_client(%{"textDocument/codeAction" => {:ok, [action]}})
      SyncServer.put_clients(buffer, [client])

      assert {:error, result} = LspCodeActions.execute(path, 0, apply: 1)
      assert result =~ "Failed to apply"
      assert result =~ "buffer is read-only"
      assert Buffer.content(buffer) == "old_name\n"
    end

    @tag :tmp_dir
    test "does not execute a command after its workspace edit fails", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "read_only_command.ex")
      File.write!(path, "old_name\n")

      buffer =
        start_supervised!(
          {BufferProcess, file_path: path, content: "old_name\n", read_only: true}
        )

      action = %{
        "title" => "Replace and organize",
        "edit" => workspace_edit(path, "new_name"),
        "command" => %{"command" => "source.organizeImports"}
      }

      client = start_fake_client(%{"textDocument/codeAction" => {:ok, [action]}})
      SyncServer.put_clients(buffer, [client])

      assert {:error, result} = LspCodeActions.execute(path, 0, apply: 1)
      assert result =~ "buffer is read-only"
      refute_receive {:lsp_request, "workspace/executeCommand"}
    end

    @tag :tmp_dir
    test "reports filesystem write failures", %{tmp_dir: tmp_dir} do
      source_path = Path.join(tmp_dir, "source.ex")
      target_path = Path.join(tmp_dir, "unwritable.ex")
      File.write!(source_path, "source\n")
      File.write!(target_path, "old_name\n")
      File.chmod!(target_path, 0o400)
      on_exit(fn -> File.chmod(target_path, 0o600) end)

      source = start_supervised!({BufferProcess, file_path: source_path, content: "source\n"})
      action = %{"title" => "Replace name", "edit" => workspace_edit(target_path, "new_name")}
      client = start_fake_client(%{"textDocument/codeAction" => {:ok, [action]}})
      SyncServer.put_clients(source, [client])

      assert {:error, result} = LspCodeActions.execute(source_path, 0, apply: 1)
      assert result =~ "could not write"
      assert File.read!(target_path) == "old_name\n"
    end

    @tag :tmp_dir
    test "propagates execute-command failures after applying workspace edits", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "command.ex")
      File.write!(path, "old_name\n")
      buffer = start_supervised!({BufferProcess, file_path: path, content: "old_name\n"})

      action = %{
        "title" => "Replace and organize",
        "edit" => workspace_edit(path, "new_name"),
        "command" => %{"command" => "source.organizeImports"}
      }

      responses = %{
        "textDocument/codeAction" => {:ok, [action]},
        "workspace/executeCommand" => {:error, %{"message" => "command rejected"}}
      }

      client = start_fake_client(responses)
      SyncServer.put_clients(buffer, [client])

      assert {:error, result} = LspCodeActions.execute(path, 0, apply: 1)
      assert result =~ "Applied \"Replace and organize\": 1 edits across 1 files"
      assert result =~ "source.organizeImports"
      assert result =~ "command rejected"
      assert Buffer.content(buffer) == "new_name"
    end
  end

  @spec workspace_edit(String.t(), String.t()) :: map()
  defp workspace_edit(path, new_text) do
    %{
      "changes" => %{
        "file://#{path}" => [
          %{
            "range" => %{
              "start" => %{"line" => 0, "character" => 0},
              "end" => %{"line" => 0, "character" => 8}
            },
            "newText" => new_text
          }
        ]
      }
    }
  end

  @spec start_fake_client(%{String.t() => {:ok, term()} | {:error, term()}}) :: pid()
  defp start_fake_client(responses) do
    owner = self()
    client = spawn(fn -> fake_client_loop(responses, owner) end)
    on_exit(fn -> Process.exit(client, :kill) end)
    client
  end

  @spec fake_client_loop(%{String.t() => {:ok, term()} | {:error, term()}}, pid()) :: no_return()
  defp fake_client_loop(responses, owner) do
    receive do
      {:"$gen_cast", {:async_request, method, _params, caller, ref}} ->
        send(owner, {:lsp_request, method})
        send(caller, {:lsp_response, ref, Map.fetch!(responses, method)})
        fake_client_loop(responses, owner)
    end
  end
end
