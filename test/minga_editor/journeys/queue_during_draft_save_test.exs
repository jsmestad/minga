defmodule MingaEditor.Journeys.QueueDuringDraftSaveTest do
  @moduledoc """
  Queueing right after typing is never refused because the composer's own autosave is still answering (#4260): the queue waits for the save and then runs.

  The test holds the Editor while the autosave timer and the queue key arrive, so the key always lands while the save is in flight, the way a fast typist's does.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Config.Options
  alias MingaAgent.Session
  alias MingaEditor.Agent.DraftSave
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Shell.Traditional.Workflow
  alias MingaEditor.State.TabBar

  @moduletag :tmp_dir
  @capabilities %Capabilities{frontend_type: :native_gui, semantic_ui: true}
  @alt 0x04
  @cmd 0x08

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
        {"a steer (⌘↩)", @cmd, {["later"], []}},
        {"a follow-up (⌥↩)", @alt, {[], ["later"]}}
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

  test "the queued item keeps the text from the press, and the composer keeps what was typed after it",
       %{
         editor_ctx: ctx,
         session: session
       } do
    press_during_autosave(ctx, session, @alt, " still")

    assert Session.get_queued_messages(session) == {[], ["later"]}
    {_session, record} = draft_save(ctx).target
    assert {:ok, [%{preview: "later"}]} = Session.queued_input_summaries(session, record)
    # Edited after the press, so the composer is kept whole rather than cleared.
    assert prompt(ctx) == "later still"
  end

  describe "a press made while the saved draft is still loading" do
    test "a send waits for the load and sends the text from the press", %{
      editor_ctx: ctx,
      session: session
    } do
      load = begin_load(ctx)
      send_keys_sync(ctx, "hello")
      send_key_sync(ctx, 13, @cmd)

      assert {:send, _kind, "hello", "hello", _marker} = draft_save(ctx).held_press
      refute minibuffer(ctx) =~ "Wait for the saved composer"

      answer_load(ctx, load, :ok)

      wait_until(ctx, fn _state -> prompt(ctx) == "" end,
        max_attempts: 500,
        interval_ms: 20,
        message: "expected the held send to be delivered once the draft loaded"
      )

      assert {:user, "hello"} in Session.messages(session)
    end

    test "a queue pressed during a turn waits for the load and queues the text from the press", %{
      editor_ctx: ctx,
      session: session
    } do
      :ok = Session.send_prompt(session, "start")
      await_working(ctx)
      load = begin_load(ctx)
      send_keys_sync(ctx, "later")
      send_key_sync(ctx, 13, @alt)

      assert {:queue, _target, :follow_up, "later", "later", _marker} = draft_save(ctx).held_press
      answer_load(ctx, load, :ok)

      wait_until(ctx, fn _state -> Session.get_queued_messages(session) == {[], ["later"]} end,
        max_attempts: 500,
        interval_ms: 20,
        message: "expected the held follow-up to be queued once the draft loaded"
      )

      refute minibuffer(ctx) =~ "Wait for the saved composer"
    end

    test "a held send sends only the pressed text and keeps what was typed after it", %{
      editor_ctx: ctx,
      session: session
    } do
      load = begin_load(ctx)
      send_keys_sync(ctx, "hello")
      send_key_sync(ctx, 13, @cmd)
      send_keys_sync(ctx, " more")
      answer_load(ctx, load, :ok)

      wait_until(ctx, fn _state -> {:user, "hello"} in Session.messages(session) end,
        max_attempts: 500,
        interval_ms: 20,
        message: "expected the pressed text to be sent once the draft loaded"
      )

      assert prompt(ctx) == "hello more"
      assert minibuffer(ctx) == "The pressed input was sent. Newer edits were kept."
    end

    test "if the load fails, the typed text stays and one line says why", %{editor_ctx: ctx} do
      load = begin_load(ctx)
      send_keys_sync(ctx, "hello")
      send_key_sync(ctx, 13, @cmd)
      answer_load(ctx, load, {:error, :stale_target})

      assert draft_save(ctx).held_press == nil
      assert prompt(ctx) == "hello"
      assert minibuffer(ctx) == "Draft not saved or restored. Current input was kept."
    end
  end

  # Re-issues the saved draft's read the way opening a conversation does, so the
  # test decides when it answers. The Session's draft is unchanged, so the answer
  # repeats the revision it already holds.
  defp begin_load(ctx) do
    owner = owner(ctx)
    ref = make_ref()
    %{target: target, buffer: buffer, request: {:ready, revision, _}} = draft_save(ctx)

    :sys.replace_state(ctx.editor, fn state ->
      ui = state.workspace.agent_ui
      loading = DraftSave.loading(target, buffer, ref, Minga.Buffer.inspection_marker(buffer))
      Workflow.install_agent_ui(state, UIState.project_draft_save(ui, loading))
    end)

    %{owner: owner, ref: ref, revision: revision, target: target}
  end

  defp answer_load(
         ctx,
         %{owner: owner, ref: ref, revision: revision, target: {session, id}},
         :ok
       ),
       do:
         send_result(
           ctx,
           {:composer_draft_result, session, id, {owner, ref}, {:ok, revision, nil}}
         )

  defp answer_load(ctx, %{owner: owner, ref: ref, target: {session, id}}, error),
    do: send_result(ctx, {:composer_draft_result, session, id, {owner, ref}, error})

  defp send_result(ctx, message) do
    send(ctx.editor, message)
    :sys.get_state(ctx.editor)
    :ok
  end

  defp press_during_autosave(ctx, session, mods, typed_after \\ "") do
    :ok = Session.send_prompt(session, "start")
    await_working(ctx)

    owner = owner(ctx)
    send_keys_sync(ctx, "later")

    # Hold the Editor, start its autosave, and press the key behind it: the key is
    # handled after the save is sent and before the Session's answer can arrive.
    start_autosave_while_held(ctx, owner)
    send(ctx.editor, {:minga_input, {:key_press, 13, mods}})

    for <<char::utf8 <- typed_after>>,
      do: send(ctx.editor, {:minga_input, {:key_press, char, 0}})

    :ok = :sys.resume(ctx.editor)

    wait_until(ctx, fn _state -> Session.get_queued_messages(session) != {[], []} end,
      max_attempts: 500,
      interval_ms: 20,
      message: "expected the held input to be queued once the save answered"
    )
  end

  # Typing arms the autosave through an asynchronous buffer event and a 350 ms
  # timer, which a loaded machine can fire at any moment. Hold the Editor while its
  # draft is ready but has unsaved edits, and arm the timer with a known token if
  # typing has not armed it yet. A real timer message already queued starts the
  # same save first, and the duplicate is ignored. If the real save got there
  # first, edit once more (net unchanged) and try again.
  defp start_autosave_while_held(ctx, owner, attempts \\ 10)

  defp start_autosave_while_held(_ctx, _owner, 0),
    do: flunk("never held the composer with unsaved edits")

  defp start_autosave_while_held(ctx, owner, attempts) do
    wait_until(
      ctx,
      fn state -> match?({:ready, _, _}, state.workspace.agent_ui.draft_save.request) end,
      max_attempts: 500,
      interval_ms: 20,
      message: "expected the composer draft to settle"
    )

    :ok = :sys.suspend(ctx.editor)
    %{workspace: %{agent_ui: %{draft_save: save}}} = :sys.get_state(ctx.editor)

    case save do
      %{request: {:ready, _, saved}, buffer: buffer} when is_pid(buffer) ->
        if Minga.Buffer.inspection_marker(buffer) == saved do
          :ok = :sys.resume(ctx.editor)
          send_keys_sync(ctx, "x<BS>")
          start_autosave_while_held(ctx, owner, attempts - 1)
        else
          send(ctx.editor, {:composer_draft_due, owner, arm_known_timer(ctx.editor)})
        end

      _settling ->
        :ok = :sys.resume(ctx.editor)
        start_autosave_while_held(ctx, owner, attempts - 1)
    end
  end

  defp arm_known_timer(editor) do
    token = make_ref()

    %{workspace: %{agent_ui: %{draft_save: %{timer: timer}}}} =
      :sys.replace_state(editor, fn state ->
        ui = state.workspace.agent_ui

        case DraftSave.schedule(ui.draft_save, token) do
          {:ok, armed} -> Workflow.install_agent_ui(state, UIState.project_draft_save(ui, armed))
          :pending -> state
        end
      end)

    timer
  end

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
      ui = UIState.set_model_name(state.workspace.agent_ui, "openai:test-model")
      Workflow.install_agent_ui(state, ui)
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
