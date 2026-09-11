defmodule MingaEditor.LspWorkspaceTranscriptTest do
  use ExUnit.Case, async: false

  @moduletag :heavy

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Diagnostics
  alias Minga.LSP.Client
  alias Minga.LSP.SyncServer
  alias Minga.Test.MockLSPServer
  alias MingaEditor.Handlers.LspEventHandler
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Windows
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  @ready_timeout 10_000

  setup do
    SyncServer.clear_registry()

    on_exit(fn ->
      SyncServer.clear_registry()
    end)

    :ok
  end

  for {wire_encoding, encoding, expected_character} <- [
        {"utf-8", :utf8, 4},
        {"utf-16", :utf16, 2},
        {"utf-32", :utf32, 1}
      ] do
    @wire_encoding wire_encoding
    @encoding encoding
    @expected_character expected_character

    test "rename transcript preserves synchronization and emoji positions for #{@wire_encoding}" do
      path =
        Path.join(
          System.tmp_dir!(),
          "lsp-transcript-#{@wire_encoding}-#{System.unique_integer([:positive])}.ex"
        )

      original = "😀foo!\n"
      synchronized = "😀foo!?\n"
      expected = "😀bar!?\n"
      File.write!(path, original)
      on_exit(fn -> File.rm(path) end)

      diagnostics =
        start_supervised!(
          {Diagnostics, name: :"transcript_diag_#{System.unique_integer([:positive])}"}
        )

      Minga.Events.subscribe(:lsp_status_changed)

      client =
        start_supervised!(
          Supervisor.child_spec(
            {Client,
             server_config: MockLSPServer.server_config(position_encoding: @wire_encoding),
             root_path: System.tmp_dir!(),
             diagnostics: diagnostics},
            id: {:transcript_client, @encoding}
          )
        )

      wait_until_ready(client)
      assert Client.encoding(client) == @encoding

      buffer =
        start_supervised!(
          {BufferProcess, file_path: path, content: original},
          id: {:transcript_buffer, @encoding}
        )

      uri = SyncServer.path_to_uri(path)
      Client.did_open(client, uri, "elixir", original, buffer, BufferProcess.version(buffer))
      assert Client.status(client) == :ready
      SyncServer.put_clients(buffer, [client])

      :ok = BufferProcess.move_to(buffer, {0, 8})
      :ok = BufferProcess.insert_text(buffer, "?")
      :ok = BufferProcess.move_to(buffer, {0, 4})
      state = editor_state(buffer)
      state = MingaEditor.LspActions.rename(state, "bar")

      assert_receive {:lsp_response, ref, {:ok, workspace_edit}}, @ready_timeout

      transcript_ref = Client.request(client, "mock/transcript", %{})
      assert_receive {:lsp_response, ^transcript_ref, {:ok, transcript}}, @ready_timeout

      assert Enum.map(transcript["events"], & &1["method"]) == [
               "textDocument/didOpen",
               "textDocument/didChange",
               "textDocument/rename"
             ]

      [open_event, change_event, rename_event] = transcript["events"]
      assert open_event["version"] == 1
      assert change_event["version"] == 2
      assert change_event["changeKind"] == "full"
      assert rename_event["documentVersion"] == 2
      assert rename_event["position"] == %{"line" => 0, "character" => @expected_character}
      assert rename_event["documentBytes"] == :binary.bin_to_list(synchronized)
      assert transcript["documents"][uri]["bytes"] == :binary.bin_to_list(synchronized)

      {_state, effects} =
        LspEventHandler.handle(state, {:lsp_response, ref, {:ok, workspace_edit}})

      assert effects == [:render_now]
      assert Minga.Buffer.content(buffer) == expected
      assert :binary.bin_to_list(Minga.Buffer.content(buffer)) == :binary.bin_to_list(expected)
    end
  end

  @spec editor_state(pid()) :: EditorState.t()
  defp editor_state(buffer) do
    workspace = %SessionState{
      buffers: %Buffers{active: buffer, list: [buffer], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(1),
        map: %{1 => Window.new(1, buffer, 24, 80)},
        active: 1,
        next_id: 2
      }
    }

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: workspace
    }
  end

  @spec wait_until_ready(pid()) :: :ok
  defp wait_until_ready(client) do
    case Client.status(client) do
      :ready ->
        :ok

      _status ->
        assert_receive {:minga_event, :lsp_status_changed,
                        %Minga.Events.LspStatusEvent{name: :mock_lsp, status: :ready}},
                       @ready_timeout
    end
  end
end
