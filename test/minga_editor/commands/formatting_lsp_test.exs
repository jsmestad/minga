defmodule MingaEditor.Commands.FormattingLSPTest do
  @moduledoc "LSP formatting dispatch, replacement, and lifecycle ownership tests."

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Commands.Formatting
  alias MingaEditor.Handlers.LspEventHandler
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.LSP, as: LSPState
  alias MingaEditor.State.Windows
  alias MingaEditor.VimState
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  test "dispatch returns while the server remains stalled" do
    state = base_state()
    buffer = state.workspace.buffers.active
    client = fake_client(self())
    register_client(buffer, client)

    new_state = Formatting.format_buffer(state)

    assert_receive {:format_request, ref, caller}
    assert caller == self()
    assert {:ok, operation} = LSPState.fetch_format(new_state.lsp, ref)
    assert operation.buffer == buffer
    assert operation.version == Minga.Buffer.version(buffer)
    assert operation.encoding == :utf16
  end

  test "client exit between capability and encoding lookup does not crash the Editor transition" do
    state = base_state()
    buffer = state.workspace.buffers.active

    client =
      start_supervised!(
        {Task,
         fn ->
           receive do
             {:"$gen_call", from, :capabilities} ->
               GenServer.reply(from, %{"documentFormattingProvider" => true})
           end
         end},
        id: {:exiting_client, make_ref()}
      )

    register_client(buffer, client)

    new_state = Formatting.format_buffer(state)

    assert LSPState.newest_format(new_state.lsp) == nil
  end

  test "a newer request for the same Buffer cancels and replaces the old request" do
    state = base_state()
    buffer = state.workspace.buffers.active
    client = fake_client(self())
    register_client(buffer, client)

    first_state = Formatting.format_buffer(state)
    assert_receive {:format_request, first_ref, _caller}

    second_state = Formatting.format_buffer(first_state)
    assert_receive {:cancel_request, ^first_ref}
    assert_receive {:format_request, second_ref, _caller}
    refute first_ref == second_ref
    refute LSPState.format_active?(second_state.lsp, first_ref)
    assert LSPState.format_active?(second_state.lsp, second_ref)

    edits = [
      %{
        "range" => %{
          "start" => %{"line" => 0, "character" => 0},
          "end" => %{"line" => 0, "character" => 5}
        },
        "newText" => "LATE"
      }
    ]

    {after_late, effects} =
      LspEventHandler.handle(second_state, {:lsp_response, first_ref, {:ok, edits}})

    assert effects == [:render_now]
    assert Minga.Buffer.content(buffer) == "hello\n"
    assert LSPState.format_active?(after_late.lsp, second_ref)
  end

  defp register_client(buffer, client) do
    Minga.LSP.SyncServer.put_clients(buffer, [client])

    on_exit(fn ->
      try do
        Minga.LSP.SyncServer.remove_buffer(buffer)
      rescue
        ArgumentError -> :ok
      end
    end)
  end

  defp fake_client(parent) do
    start_supervised!(
      {Task, fn -> fake_client_loop(parent) end},
      id: {:fake_client, make_ref()}
    )
  end

  defp fake_client_loop(parent) do
    receive do
      {:"$gen_call", from, :capabilities} ->
        GenServer.reply(from, %{"documentFormattingProvider" => true})
        fake_client_loop(parent)

      {:"$gen_call", from, :encoding} ->
        GenServer.reply(from, :utf16)
        fake_client_loop(parent)

      {:"$gen_cast", {:cancel_request, ref}} ->
        send(parent, {:cancel_request, ref})
        fake_client_loop(parent)

      {:"$gen_cast", {:async_request, "textDocument/formatting", _params, caller, ref}} ->
        send(parent, {:format_request, ref, caller})
        fake_client_loop(parent)
    end
  end

  defp base_state do
    path = Path.join(System.tmp_dir!(), "format-lsp-#{System.unique_integer([:positive])}.ex")
    File.write!(path, "hello\n")
    on_exit(fn -> File.rm(path) end)

    buffer =
      start_supervised!(
        {BufferProcess, file_path: path, content: "hello\n"},
        id: {:buffer, make_ref()}
      )

    workspace = %MingaEditor.Session.State{
      viewport: Viewport.new(24, 80),
      editing: VimState.new(),
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
end
