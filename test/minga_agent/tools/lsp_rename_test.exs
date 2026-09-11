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

    @tag :tmp_dir
    test "reports filesystem write failures", %{tmp_dir: tmp_dir} do
      source_path = Path.join(tmp_dir, "source.ex")
      target_path = Path.join(tmp_dir, "unwritable.ex")
      File.write!(source_path, "source\n")
      File.write!(target_path, "old_name\n")
      File.chmod!(target_path, 0o400)
      on_exit(fn -> File.chmod(target_path, 0o600) end)

      source = start_supervised!({BufferProcess, file_path: source_path, content: "source\n"})

      responses = %{
        "textDocument/prepareRename" =>
          {:ok,
           %{
             "start" => %{"line" => 0, "character" => 0},
             "end" => %{"line" => 0, "character" => 6}
           }},
        "textDocument/rename" => {:ok, workspace_edit(target_path, "new_name")}
      }

      client = start_fake_client(responses)
      SyncServer.put_clients(source, [client])

      assert {:error, result} = LspRename.execute(source_path, 0, 0, "new_name")
      assert result =~ "could not write"
      assert File.read!(target_path) == "old_name\n"
    end

    @tag :tmp_dir
    test "rejects a versioned edit for a closed file", %{tmp_dir: tmp_dir} do
      source_path = Path.join(tmp_dir, "source.ex")
      target_path = Path.join(tmp_dir, "closed.ex")
      File.write!(source_path, "source\n")
      File.write!(target_path, "old_name\n")
      source = start_supervised!({BufferProcess, file_path: source_path, content: "source\n"})

      responses = %{
        "textDocument/prepareRename" =>
          {:ok,
           %{
             "start" => %{"line" => 0, "character" => 0},
             "end" => %{"line" => 0, "character" => 6}
           }},
        "textDocument/rename" => {:ok, versioned_workspace_edit(target_path, "new_name", 7)}
      }

      client = start_fake_client(responses)
      SyncServer.put_clients(source, [client])

      assert {:error, result} = LspRename.execute(source_path, 0, 0, "new_name")
      assert result =~ "cannot verify document version"
      assert File.read!(target_path) == "old_name\n"
    end

    @tag :tmp_dir
    test "empty closed-file edit does not write or change metadata", %{tmp_dir: tmp_dir} do
      source_path = Path.join(tmp_dir, "source_empty.ex")
      target_path = Path.join(tmp_dir, "closed_empty.ex")
      File.write!(source_path, "source\n")
      File.write!(target_path, "unchanged\n")
      source = start_supervised!({BufferProcess, file_path: source_path, content: "source\n"})
      before_stat = File.stat!(target_path)

      responses = %{
        "textDocument/prepareRename" =>
          {:ok,
           %{
             "start" => %{"line" => 0, "character" => 0},
             "end" => %{"line" => 0, "character" => 6}
           }},
        "textDocument/rename" => {:ok, empty_workspace_edit(target_path)}
      }

      client = start_fake_client(responses)
      SyncServer.put_clients(source, [client])

      assert {:error, "Rename returned no edits to apply"} =
               LspRename.execute(source_path, 0, 0, "new_name")

      assert File.stat!(target_path) == before_stat
      assert File.read!(target_path) == "unchanged\n"
    end

    @tag :tmp_dir
    test "rejects a versioned empty edit when the open-buffer version does not match", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "empty_version_mismatch.ex")
      File.write!(path, "source\n")
      buffer = start_supervised!({BufferProcess, file_path: path, content: "source\n"})
      version = Buffer.version(buffer)
      dirty? = Buffer.dirty?(buffer)
      undo_source = BufferProcess.last_undo_source(buffer)

      responses = %{
        "textDocument/prepareRename" =>
          {:ok,
           %{
             "start" => %{"line" => 0, "character" => 0},
             "end" => %{"line" => 0, "character" => 6}
           }},
        "textDocument/rename" => {:ok, versioned_empty_workspace_edit(path, 2)}
      }

      client = start_fake_client(responses)
      SyncServer.put_clients(buffer, [client])

      assert {:error, result} = LspRename.execute(path, 0, 0, "new_name")
      assert result =~ "version_mismatch"
      assert Buffer.content(buffer) == "source\n"
      assert Buffer.version(buffer) == version
      assert Buffer.dirty?(buffer) == dirty?
      assert BufferProcess.last_undo_source(buffer) == undo_source
    end

    @tag :tmp_dir
    test "rejects a versioned empty edit for a closed file without touching metadata", %{
      tmp_dir: tmp_dir
    } do
      source_path = Path.join(tmp_dir, "empty_closed_source.ex")
      target_path = Path.join(tmp_dir, "empty_closed_target.ex")
      File.write!(source_path, "source\n")
      File.write!(target_path, "unchanged\n")
      source = start_supervised!({BufferProcess, file_path: source_path, content: "source\n"})
      before_stat = File.stat!(target_path)

      responses = %{
        "textDocument/prepareRename" =>
          {:ok,
           %{
             "start" => %{"line" => 0, "character" => 0},
             "end" => %{"line" => 0, "character" => 6}
           }},
        "textDocument/rename" => {:ok, versioned_empty_workspace_edit(target_path, 7)}
      }

      client = start_fake_client(responses)
      SyncServer.put_clients(source, [client])

      assert {:error, result} = LspRename.execute(source_path, 0, 0, "new_name")
      assert result =~ "cannot verify document version"
      assert File.stat!(target_path) == before_stat
      assert File.read!(target_path) == "unchanged\n"
    end

    @tag :tmp_dir
    test "neutral empty document does not inflate mixed rename counts", %{tmp_dir: tmp_dir} do
      source_path = Path.join(tmp_dir, "mixed_source.ex")
      target_path = Path.join(tmp_dir, "mixed_empty.ex")
      File.write!(source_path, "old_name\n")
      File.write!(target_path, "unchanged\n")
      source = start_supervised!({BufferProcess, file_path: source_path, content: "old_name\n"})
      before_stat = File.stat!(target_path)

      responses = %{
        "textDocument/prepareRename" =>
          {:ok,
           %{
             "start" => %{"line" => 0, "character" => 0},
             "end" => %{"line" => 0, "character" => 8}
           }},
        "textDocument/rename" => {:ok, mixed_workspace_edit(source_path, target_path, "new_name")}
      }

      client = start_fake_client(responses)
      SyncServer.put_clients(source, [client])

      assert {:ok, "Renamed to `new_name` across 1 file (1 edits)"} =
               LspRename.execute(source_path, 0, 0, "new_name")

      assert Buffer.content(source) == "new_name\n"
      assert File.stat!(target_path) == before_stat
      assert File.read!(target_path) == "unchanged\n"
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

  @spec versioned_workspace_edit(String.t(), String.t(), non_neg_integer()) :: map()
  defp versioned_workspace_edit(path, new_text, version) do
    %{
      "documentChanges" => [
        %{
          "textDocument" => %{"uri" => "file://#{path}", "version" => version},
          "edits" => workspace_edit(path, new_text)["changes"]["file://#{path}"]
        }
      ]
    }
  end

  @spec empty_workspace_edit(String.t()) :: map()
  defp empty_workspace_edit(path) do
    %{
      "documentChanges" => [
        %{"textDocument" => %{"uri" => "file://#{path}", "version" => nil}, "edits" => []}
      ]
    }
  end

  @spec versioned_empty_workspace_edit(String.t(), non_neg_integer()) :: map()
  defp versioned_empty_workspace_edit(path, version) do
    %{
      "documentChanges" => [
        %{
          "textDocument" => %{"uri" => "file://#{path}", "version" => version},
          "edits" => []
        }
      ]
    }
  end

  @spec mixed_workspace_edit(String.t(), String.t(), String.t()) :: map()
  defp mixed_workspace_edit(source_path, empty_path, new_text) do
    %{
      "documentChanges" => [
        %{
          "textDocument" => %{"uri" => "file://#{source_path}", "version" => nil},
          "edits" => workspace_edit(source_path, new_text)["changes"]["file://#{source_path}"]
        },
        %{
          "textDocument" => %{"uri" => "file://#{empty_path}", "version" => nil},
          "edits" => []
        }
      ]
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
      {:"$gen_call", from, :encoding} ->
        GenServer.reply(from, :utf16)
        fake_client_loop(responses)

      {:"$gen_call", from, {:validate_document_version, _uri, _wire_version, _buffer, _revision}} ->
        GenServer.reply(from, {:error, :version_mismatch})
        fake_client_loop(responses)

      {:"$gen_cast", {:async_request, method, _params, caller, ref}} ->
        send(caller, {:lsp_response, ref, Map.fetch!(responses, method)})
        fake_client_loop(responses)
    end
  end
end
