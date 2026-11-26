defmodule MingaEditor.Journeys.QueueRestoreTest do
  # The Sessions picker and local Session both read the default XDG config root; config tests replace it while running.
  use Minga.Test.EditorCase, async: false

  alias Minga.Config.Options
  alias MingaAgent.Session.Continuation
  alias MingaAgent.SessionStore
  alias MingaAgent.TurnUsage
  alias MingaEditor.Agent.QueueSurface
  alias MingaEditor.Frontend.Capabilities

  @tag :tmp_dir
  test "reopening a saved conversation shows its pending queue without taking focus", %{
    tmp_dir: dir
  } do
    suffix = System.unique_integer([:positive])
    record = "restore-queue-#{suffix}"
    title = "Restored queue #{suffix}"
    message = "This message was kept in the saved queue"
    options = start_supervised!(Supervisor.child_spec({Options, name: nil}, id: make_ref()))
    file = Path.join(dir, "restore.txt")
    File.write!(file, "A file open before Agent starts")

    assert :ok =
             SessionStore.save(%{
               id: record,
               timestamp: DateTime.to_iso8601(DateTime.utc_now()),
               model_name: "Offline queue fixture",
               provider_name: "native",
               custom_title: title,
               messages: [{:user, title}],
               continuation: Continuation.new(),
               usage: TurnUsage.new(),
               pending_inputs: {2, [], [{1, 1, message, [], nil}], []}
             })

    ctx =
      start_editor("A file open before Agent starts",
        file_path: file,
        project_root: dir,
        shell: :traditional,
        capabilities: %Capabilities{frontend_type: :native_gui, semantic_ui: true},
        options_server: options,
        agent_provider_module: Minga.Test.SessionSlowMockProvider,
        agent_arrival_budget_ms: 4_000
      )

    send_keys_sync(ctx, "<SPC>aSh")
    send_keys_sync(ctx, title)

    wait_until(ctx, fn _state ->
      %{picker_ui: %{activation_offer: offer}} = modal_picker!(ctx)
      Enum.any?(offer.items, fn {_, _, item} -> match?({^record, {:disk, _}}, item.id) end)
    end)

    send_keys_sync(ctx, "<CR>")

    state =
      wait_until(
        ctx,
        fn state ->
          match?(
            %{origin: {_, _, ^record}, contents: %{pending: [%{preview: ^message}]}},
            state.workspace.agent_ui.queue
          )
        end,
        max_attempts: 500,
        message: "expected the saved queue to appear before focusing it"
      )

    assert QueueSurface.visible?(state.workspace.agent_ui.queue)
    refute QueueSurface.focused?(state.workspace.agent_ui.queue)
  end
end
