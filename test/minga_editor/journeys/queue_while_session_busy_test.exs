defmodule MingaEditor.Journeys.QueueWhileSessionBusyTest do
  @moduledoc """
  A fast typist queues five follow-ups while Minga works, typing the next one before the last is confirmed (#4260).

  The Session is suspended for the five presses, the way a Session busy with a turn answers late. Every press must return at once (the Editor never waits on the Session), and once the Session answers, the queue holds exactly the five pressed texts, in order, and the composer is empty.
  """

  # Mention resolution reads the global `Minga.Project` workspace root, which this
  # module points at its own project for the file-mention case.
  use Minga.Test.EditorCase, async: false

  alias Minga.Config.Options
  alias Minga.Project
  alias Minga.Project.Root
  alias MingaAgent.FileMention
  alias MingaAgent.Session
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Shell.Traditional.Workflow

  @moduletag :tmp_dir
  @capabilities %Capabilities{frontend_type: :native_gui, semantic_ui: true}
  @alt 0x04

  # A press that waited on the suspended Session would take its 5 s call timeout.
  @press_budget_us 1_000_000

  setup %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/a.ex"), "defmodule A do\nend\n")
    path = Path.join(dir, "journey.txt")
    File.write!(path, "A file beside the conversation")

    Project.close()
    {:ok, root} = Root.directory(dir)
    {:ok, _snapshot} = Project.activate(root)
    on_exit(fn -> Project.close() end)

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

  for {label, texts} <- [
        {"plain text", ["alpha one", "bravo two", "charlie three", "delta four", "echo five"]},
        {"a file mention",
         [
           "alpha @lib/a.ex now",
           "bravo two",
           "charlie @lib/a.ex three",
           "delta four",
           "echo five"
         ]}
      ] do
    @texts texts

    test "five presses with typing between them queue exactly the pressed texts (#{label})", %{
      editor_ctx: ctx,
      session: session
    } do
      :ok = Session.send_prompt(session, "start")
      await_working(ctx)
      :ok = :sys.suspend(session)

      for text <- @texts do
        {elapsed, _state} =
          :timer.tc(fn ->
            send_keys_sync(ctx, text)
            send_key_sync(ctx, 13, @alt)
          end)

        assert elapsed < @press_budget_us,
               "pressing ⌥↩ after #{inspect(text)} waited #{div(elapsed, 1000)} ms on the Session"

        refute minibuffer(ctx) =~ "Wait for"
      end

      :ok = :sys.resume(session)
      {_session, record} = editor_state(ctx).workspace.agent_ui.draft_save.target

      wait_until(
        ctx,
        fn _state ->
          match?({:ok, [_, _, _, _, _]}, Session.queued_input_summaries(session, record)) and
            prompt(ctx) == ""
        end,
        max_attempts: 500,
        interval_ms: 20,
        message: "expected five queued follow-ups and an empty composer"
      )

      {:ok, summaries} = Session.queued_input_summaries(session, record)
      assert Enum.map(summaries, & &1.preview) == @texts
      assert Enum.all?(summaries, &(&1.kind == :follow_up))
      refute minibuffer(ctx) =~ "Newer edits were kept"
    end
  end

  test "files a message names are read off the Editor, and the presses keep their order", %{
    editor_ctx: ctx,
    session: session
  } do
    texts = ["alpha @lib/a.ex now", "bravo two", "charlie @lib/a.ex three"]
    :ok = Session.send_prompt(session, "start")
    await_working(ctx)

    # Trace the Editor process while the keys are pressed: resolving a mention (the
    # project root, the files it names) must happen in a worker, never here.
    editor = ctx.editor

    traced = [
      {FileMention, :resolve_prompt, :_},
      {Project, :workspace_root, :_},
      {File, :read, :_}
    ]

    :erlang.trace(editor, true, [:call, {:tracer, self()}])
    for mfa <- traced, do: :erlang.trace_pattern(mfa, true, [:local])

    on_exit(fn ->
      for mfa <- traced, do: :erlang.trace_pattern(mfa, false, [:local])
    end)

    for text <- texts do
      send_keys_sync(ctx, text)
      send_key_sync(ctx, 13, @alt)
    end

    {_session, record} = editor_state(ctx).workspace.agent_ui.draft_save.target

    wait_until(
      ctx,
      fn _state ->
        match?({:ok, [_, _, _]}, Session.queued_input_summaries(session, record)) and
          prompt(ctx) == ""
      end,
      max_attempts: 500,
      interval_ms: 20,
      message: "expected three queued follow-ups and an empty composer"
    )

    :erlang.trace(editor, false, [:call])

    {:ok, summaries} = Session.queued_input_summaries(session, record)
    assert Enum.map(summaries, & &1.preview) == texts
    assert [mentioned, _plain, _second] = Session.get_queued_messages(session) |> elem(1)
    assert inspect(mentioned) =~ "defmodule A"

    for {module, function, _arity} <- traced do
      refute_received {:trace, ^editor, :call, {^module, ^function, _args}},
                      "the Editor called #{inspect(module)}.#{function} while a key was pressed"
    end
  end

  test "a file that cannot be read stops its press and every press behind it; all the text stays",
       %{editor_ctx: ctx, session: session} do
    :ok = Session.send_prompt(session, "start")
    await_working(ctx)

    send_keys_sync(ctx, "see @missing.ex now")
    send_key_sync(ctx, 13, @alt)
    send_keys_sync(ctx, "also tests")
    send_key_sync(ctx, 13, @alt)

    wait_until(ctx, fn _state -> minibuffer(ctx) =~ "not sent" end,
      max_attempts: 500,
      interval_ms: 20,
      message: "expected one line saying the message was not sent"
    )

    {_session, record} = editor_state(ctx).workspace.agent_ui.draft_save.target
    assert Session.queued_input_summaries(session, record) == {:ok, []}
    assert prompt(ctx) == "see @missing.ex nowalso tests"
    assert editor_state(ctx).workspace.agent_ui.draft_save.held_presses == []

    # The composer takes presses again: the whole text goes as one message.
    send_key_sync(ctx, 13, @alt)

    wait_until(ctx, fn _state -> minibuffer(ctx) =~ "not sent" and prompt(ctx) != "" end,
      max_attempts: 50,
      message: "expected the missing file to be reported again"
    )
  end

  test "a read of mentioned files always answers, even when the project never does" do
    # The read runs here because no effect scheduler is given; a Project that never
    # answers makes its call exit, and the read must still answer with a failure.
    :ok = :sys.suspend(Project)

    try do
      :ok =
        MingaEditor.Agent.DraftWorkflow.read_mentions_off_editor(
          :no_scheduler,
          "see @lib/a.ex",
          UIState.new(),
          &{:read, &1}
        )
    after
      :sys.resume(Project)
    end

    assert_received {:read, {:error, "Could not read the files the message names."}}
  end

  test "text typed after the last press stays, and one more press queues only it", %{
    editor_ctx: ctx,
    session: session
  } do
    :ok = Session.send_prompt(session, "start")
    await_working(ctx)
    :ok = :sys.suspend(session)

    send_keys_sync(ctx, "first")
    send_key_sync(ctx, 13, @alt)
    send_keys_sync(ctx, "second")

    :ok = :sys.resume(session)
    {_session, record} = editor_state(ctx).workspace.agent_ui.draft_save.target

    wait_until(ctx, fn _state -> prompt(ctx) == "second" end,
      max_attempts: 500,
      interval_ms: 20,
      message: "expected only the text typed after the press to stay"
    )

    # The cursor stays at the end of what was kept, so typing continues there.
    send_keys_sync(ctx, "!")
    assert prompt(ctx) == "second!"

    send_key_sync(ctx, 13, @alt)

    wait_until(ctx, fn _state -> prompt(ctx) == "" end,
      max_attempts: 500,
      interval_ms: 20,
      message: "expected the second press to clear the composer"
    )

    {:ok, summaries} = Session.queued_input_summaries(session, record)
    assert Enum.map(summaries, & &1.preview) == ["first", "second!"]
  end

  defp await_session(ctx) do
    state =
      wait_until(
        ctx,
        fn state ->
          session = Runtime.active_session(state.shell_runtime)

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

  defp prompt(ctx),
    do: MingaEditor.Agent.PromptBuffer.input_text(editor_state(ctx).workspace.agent_ui)
end
