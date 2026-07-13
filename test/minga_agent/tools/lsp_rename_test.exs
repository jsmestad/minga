defmodule MingaAgent.Tools.LspRenameTest do
  # async: false because this test registers a fake client in the shared SyncServer singleton.
  use ExUnit.Case, async: false

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.LSP.SyncServer
  alias MingaAgent.Tools.LspRename

  setup do
    SyncServer.clear_registry()
    on_exit(&SyncServer.clear_registry/0)
    :ok
  end

  describe "execute/4 without LSP client" do
    test "returns error when no buffer exists" do
      {:error, result} = LspRename.execute("/nonexistent/file.ex", 10, 5, "new_name")
      assert result =~ "No buffer open"
      assert result =~ "file must be open"
    end
  end

  describe "execute/4 with edits" do
    @tag :tmp_dir
    test "returns an error when the target buffer is read-only", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "read_only.ex")
      File.write!(path, "old_name\n")

      buffer =
        start_supervised!(
          {BufferProcess, file_path: path, content: "old_name\n", read_only: true}
        )

      responses = %{
        "textDocument/prepareRename" =>
          {:ok,
           %{
             "start" => %{"line" => 0, "character" => 0},
             "end" => %{"line" => 0, "character" => 8}
           }},
        "textDocument/rename" => {:ok, workspace_edit(path, "new_name")}
      }

      client = start_fake_client(responses)
      SyncServer.put_clients(buffer, [client])

      assert {:error, result} = LspRename.execute(path, 0, 0, "new_name")
      assert result =~ "Failed to rename"
      assert result =~ "buffer is read-only"
      assert Buffer.content(buffer) == "old_name\n"
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
    client = spawn(fn -> fake_client_loop(responses) end)
    on_exit(fn -> Process.exit(client, :kill) end)
    client
  end

  @spec fake_client_loop(%{String.t() => {:ok, term()} | {:error, term()}}) :: no_return()
  defp fake_client_loop(responses) do
    receive do
      {:"$gen_cast", {:async_request, method, _params, caller, ref}} ->
        send(caller, {:lsp_response, ref, Map.fetch!(responses, method)})
        fake_client_loop(responses)
    end
  end
end
