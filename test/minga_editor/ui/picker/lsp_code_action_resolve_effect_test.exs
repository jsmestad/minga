defmodule MingaEditor.UI.Picker.LspCodeActionResolveEffectTest do
  @moduledoc "Behavior tests for supervised deferred code-action resolve."

  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.LSP.DocumentContext
  alias Minga.LSP.SyncServer
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State.LSP, as: LSPState
  alias MingaEditor.UI.Picker.CodeActionSource
  alias MingaEditor.UI.Picker.Item

  @effect_timeout 2_000

  test "resolve runs outside the Editor and suppresses the command when its resolved edit fails" do
    task_supervisor = start_supervised!({Task.Supervisor, []})

    scheduler =
      start_supervised!({EffectScheduler, task_supervisor: task_supervisor, observer: self()})

    :ok = EffectScheduler.attach(scheduler, self())

    state =
      TestHelpers.base_state(
        content: "hello\n",
        effect_scheduler: scheduler,
        rendering: :disabled
      )

    buffer = state.workspace.buffers.active

    path =
      Path.join(System.tmp_dir!(), "lsp-resolve-effect-#{System.unique_integer([:positive])}.ex")

    File.write!(path, "hello\n")
    on_exit(fn -> File.rm(path) end)
    :ok = BufferProcess.open(buffer, path)

    test_pid = self()
    client = start_supervised!({Task, fn -> fake_client_loop(test_pid) end})
    SyncServer.put_clients(buffer, [client])
    on_exit(fn -> SyncServer.remove_buffer(buffer) end)

    context = %DocumentContext{
      client: client,
      buffer: buffer,
      uri: SyncServer.path_to_uri(path),
      buffer_revision: Minga.Buffer.version(buffer),
      lsp_version: 1,
      encoding: :utf16
    }

    action = %{"title" => "Deferred", "data" => %{"id" => 7}}
    pending_ref = make_ref()

    lsp =
      LSPState.track_workspace_response_request(
        state.lsp,
        pending_ref,
        :code_action,
        context,
        nil,
        {0, 0}
      )

    assert {:ok, {:workspace_response, :code_action, generation, ^context, nil, {0, 0}}} =
             LSPState.fetch_pending_request(lsp, pending_ref)

    state = %{state | lsp: lsp}
    item = %Item{id: {0, action, context, generation}, label: "Deferred"}

    assert ^state = CodeActionSource.on_select(item, state)

    assert_receive {:resolve_request, worker, ref, ^action}, @effect_timeout

    resolved = %{
      "title" => "Deferred",
      "edit" => %{
        "changes" => %{
          context.uri => [
            %{
              "range" => %{
                "start" => %{"line" => 99, "character" => 0},
                "end" => %{"line" => 99, "character" => 1}
              },
              "newText" => "broken"
            }
          ]
        }
      },
      "command" => %{"command" => "test.must_not_run"}
    }

    send(worker, {:lsp_response, ref, {:ok, resolved}})

    assert_receive {:effect_result, ^scheduler, %Outcome{} = outcome}, @effect_timeout

    assert {:noreply, result} =
             MingaEditor.handle_info({:effect_result, scheduler, outcome}, state)

    assert Minga.Buffer.content(buffer) == "hello\n"
    assert NoticeWorkflow.message(result) =~ "could not apply edits"
    refute_receive {:client_request, "workspace/executeCommand", _params}
  end

  defp fake_client_loop(parent) do
    receive do
      {:"$gen_call", from, {:validate_document_version, _uri, 1, _buffer, _revision}} ->
        GenServer.reply(from, :ok)
        fake_client_loop(parent)

      {:"$gen_cast", {:async_request, "codeAction/resolve", action, caller, ref}} ->
        send(parent, {:resolve_request, caller, ref, action})
        fake_client_loop(parent)

      {:"$gen_cast", {:async_request, method, params, _caller, _ref}} ->
        send(parent, {:client_request, method, params})
        fake_client_loop(parent)

      _other ->
        fake_client_loop(parent)
    end
  end
end
