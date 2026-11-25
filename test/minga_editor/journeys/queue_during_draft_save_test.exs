defmodule MingaEditor.Journeys.QueueDuringDraftSaveTest do
  @moduledoc """
  Queueing right after typing is never refused because the composer's own autosave is still answering (#4260): the queue waits for the save and then runs.

  The test holds the Editor while the autosave timer and the queue key arrive, so the key always lands while the save is in flight, the way a fast typist's does.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Config.Options
  alias MingaAgent.Session
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.TabBar

  @moduletag :tmp_dir
  @capabilities %Capabilities{frontend_type: :native_gui, semantic_ui: true}
  @ctrl 0x02

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
    Minga.Test.AgentWorkflowDriver.focus_prompt(ctx)
    configure_model(ctx)
    %{editor_ctx: ctx, session: session}
  end

  # {what the key does, the key, the queue the text lands in}
  for {kind, mods, expected} <- [
        {"a steer", 0, {["later"], []}},
        {"a follow-up", @ctrl, {[], ["later"]}}
      ] do
    @mods mods
    @expected expected

    test "#{kind} pressed while the draft's autosave is in flight is queued, not refused", %{
      editor_ctx: ctx,
      session: session
    } do
      press_during_autosave(ctx, session, @mods)
      assert Session.get_queued_messages(session) == @expected
      refute minibuffer(ctx) =~ "Wait for the saved composer"
    end
  end

  defp press_during_autosave(ctx, session, mods) do
    :ok = Session.send_prompt(session, "start")
    await_working(ctx)

    send_keys_sync(ctx, "later")
    owner = owner(ctx)
    %{timer: token} = draft_save(ctx)
    assert is_reference(token), "typing arms the composer's autosave"

    # Both messages wait in the Editor's mailbox, so the queue key is handled
    # after the autosave is sent and before the Session's answer can arrive.
    :ok = :sys.suspend(ctx.editor)
    send(ctx.editor, {:composer_draft_due, owner, token})
    send(ctx.editor, {:minga_input, {:key_press, 13, mods}})
    :ok = :sys.resume(ctx.editor)

    wait_until(ctx, fn _state -> prompt(ctx) == "" end,
      max_attempts: 200,
      message: "expected the held input to be queued once the save answered"
    )
  end

  defp await_session(ctx) do
    state =
      wait_until(
        ctx,
        fn state ->
          session = Runtime.active_session(state.shell_runtime)

          is_pid(session) and
            match?(
              %{connection: %{provider_phase: :running, target: %{session: ^session}}},
              state.workspace.agent_ui
            )
        end,
        max_attempts: 500,
        interval_ms: 20,
        message: "expected SPC a v to attach a running session"
      )

    Runtime.active_session(state.shell_runtime)
  end

  defp await_working(ctx) do
    wait_until(
      ctx,
      fn state ->
        agent = TraditionalState.agent(state.shell_runtime.state)

        agent.runtime.status in [:thinking, :tool_executing] and agent.queue_target != nil and
          match?(%{request: {:ready, _, _}}, state.workspace.agent_ui.draft_save)
      end,
      max_attempts: 200,
      message: "expected Minga to be working with a saved composer"
    )
  end

  defp configure_model(%{editor: editor}) do
    :sys.replace_state(editor, fn state ->
      ui = MingaEditor.Agent.UIState.set_model_name(state.workspace.agent_ui, "openai:test-model")
      MingaEditor.Shell.Traditional.Workflow.install_agent_ui(state, ui)
    end)

    :ok
  end

  defp draft_save(ctx), do: editor_state(ctx).workspace.agent_ui.draft_save

  defp owner(ctx),
    do:
      ctx
      |> editor_state()
      |> Map.fetch!(:shell_runtime)
      |> Runtime.state()
      |> Map.fetch!(:tab_bar)
      |> TabBar.active_workspace_id()

  defp prompt(ctx),
    do: MingaEditor.Agent.PromptBuffer.input_text(editor_state(ctx).workspace.agent_ui)
end
