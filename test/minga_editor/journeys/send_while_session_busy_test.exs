defmodule MingaEditor.Journeys.SendWhileSessionBusyTest do
  @moduledoc """
  Sending never holds the Editor on the Session (#4296).

  The Session is suspended for the press, the way a Session whose provider is still preparing the request answers late. The press must return at once with the text still in the composer, typing must go on, and once the Session answers exactly the pressed text is sent and removed, in front or in a background tab.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Config.Options
  alias MingaAgent.Session
  alias MingaEditor.Agent.TurnRequest
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State.TabBar

  @moduletag :tmp_dir
  @capabilities %Capabilities{frontend_type: :native_gui, semantic_ui: true}

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "journey.txt")
    File.write!(path, "A file beside the conversation")
    options = start_supervised!(Supervisor.child_spec({Options, name: nil}, id: make_ref()))

    ctx =
      start_editor("A file beside the conversation",
        file_path: path,
        project_root: dir,
        shell: :traditional,
        capabilities: @capabilities,
        options_server: options,
        agent_provider_module: Minga.Test.SessionSlowMockProvider,
        agent_arrival_budget_ms: 4_000
      )

    send_keys_sync(ctx, "<SPC>av")
    session = await_session(ctx)
    configure_model(ctx)
    %{editor_ctx: ctx, session: session}
  end

  test "a send pressed while the Session is busy returns, typing goes on, and one message is sent",
       %{editor_ctx: ctx, session: session} do
    send_keys_sync(ctx, "hello<Esc>")
    :ok = :sys.suspend(session)

    send_keys_sync(ctx, "<CR>")
    assert [%TurnRequest{session: ^session, work: {:send, _, "hello", "hello"}}] = sends(ctx)
    assert prompt(ctx) == "hello"

    # A second press with nothing new to send, then more typing: neither waits on the Session.
    send_keys_sync(ctx, "<CR>")
    send_keys_sync(ctx, "A and more<Esc>")
    assert prompt(ctx) == "hello and more"
    assert [_one_send] = sends(ctx)

    :ok = :sys.resume(session)
    assert user_messages(session) == ["hello"]
    assert prompt(ctx) == " and more"
    assert sends(ctx) == []
  end

  test "two presses on a late answer: the first sends, the second queues, and nothing is refused",
       %{editor_ctx: ctx, session: session} do
    send_keys_sync(ctx, "first<Esc>")
    :ok = :sys.suspend(session)
    send_keys_sync(ctx, "<CR>")

    # The second message is typed and sent before the Session has answered the first.
    send_keys_sync(ctx, "Asecond<Esc><CR>")
    assert [_one_send] = sends(ctx)
    assert prompt(ctx) == "firstsecond"

    :ok = :sys.resume(session)

    # The first answer names the turn it started, so the press behind it queues into that turn.
    wait_until(ctx, fn _state -> Session.get_queued_messages(session) == {["second"], []} end,
      message: "expected the second press to be queued behind the first message"
    )

    assert user_messages(session) == ["first"]
    await_prompt(ctx, "")
    refute minibuffer(ctx) =~ "The Agent turn changed"
    refute minibuffer(ctx) =~ "not sent"
  end

  test "an answer that arrives while the conversation is in a background tab clears only that composer",
       %{editor_ctx: ctx, session: session} do
    send_keys_sync(ctx, "hello<Esc>")
    agent_workspace = front_workspace(ctx)
    :ok = :sys.suspend(session)
    send_keys_sync(ctx, "<CR>")
    assert [%TurnRequest{workspace: ^agent_workspace}] = sends(ctx)

    # A new conversation takes the front before the Session answers, so the answer is
    # handled with the pressed conversation in the background.
    send_keys_async(ctx, "<SPC>an")

    wait_until(ctx, fn _state -> front_workspace(ctx) != agent_workspace end,
      message: "expected the new conversation in front"
    )

    :ok = :sys.resume(session)
    assert user_messages(session) == ["hello"]
    assert sends(ctx) == []
    assert background_prompt(ctx, agent_workspace) == ""
  end

  test "a Session that exits before it answers keeps the message in the composer", %{
    editor_ctx: ctx,
    session: session
  } do
    send_keys_sync(ctx, "hello<Esc>")
    :ok = :sys.suspend(session)
    send_keys_sync(ctx, "<CR>")
    assert [%TurnRequest{}] = sends(ctx)

    monitor = Process.monitor(session)
    Process.exit(session, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^session, :killed}

    wait_until(ctx, fn _state -> sends(ctx) == [] end,
      message: "expected the send to end when its Session exited"
    )

    assert prompt(ctx) == "hello"
  end

  defp background_prompt(ctx, workspace) do
    %{payload: %{agent_ui: ui}} =
      TabBar.get_workspace(editor_state(ctx).shell_runtime.state.tab_bar, workspace)

    MingaEditor.Agent.PromptBuffer.input_text(ui)
  end

  defp sends(ctx), do: Map.values(editor_state(ctx).agent_connection.turn_requests)

  defp front_workspace(ctx),
    do: TabBar.active_workspace_id(editor_state(ctx).shell_runtime.state.tab_bar)

  defp await_session(ctx) do
    state =
      wait_until(
        ctx,
        fn state ->
          session = Runtime.active_session(state.shell_runtime)

          # The composer sends through its saved draft, so wait for that draft to load too.
          is_pid(session) and
            match?(
              %{
                connection: %{provider_phase: :running, target: %{session: ^session}},
                draft_save: %{target: {^session, _}, request: {:ready, _, _}}
              },
              state.workspace.agent_ui
            )
        end,
        max_attempts: 500,
        interval_ms: 20,
        message: "expected SPC a v to attach a running session with its draft loaded"
      )

    Runtime.active_session(state.shell_runtime)
  end

  # The mock provider reports no model selection, so the panel would block sends as
  # "No model configured"; name a configured model the way a picked model does.
  defp configure_model(%{editor: editor}) do
    :sys.replace_state(editor, fn state ->
      ui = MingaEditor.Agent.UIState.set_model_name(state.workspace.agent_ui, "openai:test-model")
      MingaEditor.Shell.Traditional.Workflow.install_agent_ui(state, ui)
    end)

    :ok
  end

  defp await_prompt(ctx, expected) do
    wait_until(ctx, fn _state -> prompt(ctx) == expected end,
      max_attempts: 200,
      message: "expected the composer to read #{inspect(expected)}"
    )
  end

  defp prompt(ctx),
    do: MingaEditor.Agent.PromptBuffer.input_text(editor_state(ctx).workspace.agent_ui)

  defp user_messages(session) do
    for {:user, text} <- Session.messages(session), do: text
  end
end
