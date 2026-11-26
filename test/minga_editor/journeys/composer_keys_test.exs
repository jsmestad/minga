defmodule MingaEditor.Journeys.ComposerKeysTest do
  @moduledoc """
  The composer behaves like a Vim buffer: it opens in Insert, `↩` adds a newline while typing, and Normal-mode `↩` or `⌘↩` sends. `⌥↩` queues, `SPC a s` and `⌘.` stop and keep the queue, and `q` closes the split only outside the composer (docs/design/keys.md, Composer; #4055).

  The slow mock provider starts a turn and never finishes it, so a sent prompt leaves Minga working until it is stopped.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Config.Options
  alias Minga.Design.Tokens
  alias MingaAgent.Session
  alias MingaEditor.Agent.Tasks
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Session.ChromeState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.Modeline
  alias MingaEditor.StatusBar.Data, as: StatusBarData

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
    configure_model(ctx)
    %{editor_ctx: ctx, session: session}
  end

  test "SPC a v opens the conversation with the composer focused in Insert", %{editor_ctx: ctx} do
    state = editor_state(ctx)
    assert state.workspace.agent_ui.panel.input_focused
    assert editor_mode(ctx) == :insert
    assert state.workspace.keymap_scope == :agent
  end

  test "Enter adds a newline in Insert; Normal-mode Enter sends", %{
    editor_ctx: ctx,
    session: session
  } do
    send_keys_sync(ctx, "first<CR>second")
    assert prompt(ctx) == "first\nsecond"
    assert user_messages(session) == []

    send_keys_sync(ctx, "<Esc><CR>")

    # The send is answered in the Editor's mailbox, so the composer clears when the answer lands.
    assert user_messages(session) == ["first\nsecond"]
    await_prompt(ctx, "")
  end

  test "a pending count or operator keeps Enter for Vim instead of sending", %{
    editor_ctx: ctx,
    session: session
  } do
    send_keys_sync(ctx, "one<CR>two<CR>three<Esc>gg2<CR>")
    assert user_messages(session) == []
    assert prompt(ctx) == "one\ntwo\nthree"

    send_keys_sync(ctx, "ggd<CR><Esc>")
    assert user_messages(session) == []
    assert prompt(ctx) == "one\ntwo\nthree"
  end

  test "Cmd+Enter sends from Insert, and sending while Minga works steers", %{
    editor_ctx: ctx,
    session: session
  } do
    send_keys_sync(ctx, "start")
    send_key_sync(ctx, 13, @cmd)
    assert user_messages(session) == ["start"]
    await_working(ctx)

    send_keys_sync(ctx, "steer")
    send_key_sync(ctx, 13, @cmd)
    await_prompt(ctx, "")
    assert Session.get_queued_messages(session) == {["steer"], []}
  end

  test "Alt+Enter queues the next message while Minga works", %{
    editor_ctx: ctx,
    session: session
  } do
    send_keys_sync(ctx, "start")
    send_key_sync(ctx, 13, @cmd)
    await_working(ctx)

    queue(ctx, "later")
    assert Session.get_queued_messages(session) == {[], ["later"]}
  end

  for {label, stop} <- [{"SPC a s", "<Esc><Esc><SPC>as"}, {"Cmd+.", :cmd_period}] do
    test "#{label} stops, keeps the queue and the draft, and the modeline says Minga stopped", %{
      editor_ctx: ctx,
      session: session
    } do
      send_keys_sync(ctx, "go")
      send_key_sync(ctx, 13, @cmd)
      await_working(ctx)
      queue(ctx, "later")
      send_keys_sync(ctx, "draft")

      case unquote(stop) do
        :cmd_period -> send_key_sync(ctx, ?., @cmd)
        keys -> send_keys_sync(ctx, keys)
      end

      assert Session.status(session) == :stopped
      assert Session.get_queued_messages(session) == {[], ["later"]}
      assert prompt(ctx) == "draft"

      wait_until(ctx, fn _state -> modeline(ctx) =~ "Minga stopped" end,
        message: "expected the modeline to say Minga stopped"
      )
    end
  end

  for {input, draft} <- [{:keyboard, ""}, {:click, "not yet"}] do
    test "Continue via #{input} resumes the interrupted response without sending the draft or queue",
         %{editor_ctx: ctx, session: session} do
      send_keys_sync(ctx, "go")
      send_key_sync(ctx, 13, @cmd)
      await_working(ctx)
      queue(ctx, "later")
      await_prompt(ctx, "")
      send_keys_sync(ctx, unquote(draft))

      %{stop_target: interrupted} = Session.editor_snapshot(session)
      send_key_sync(ctx, ?., @cmd)

      wait_until(ctx, fn _state -> modeline(ctx) =~ "Minga stopped" end,
        message: "expected the exact stopped turn to be displayed"
      )

      assert %{continue_target: ^interrupted} = Session.editor_snapshot(session)
      {record, _request} = interrupted
      send_gui_action(ctx, {:agent_continue_turn, {record, "another request"}})
      assert Session.status(session) == :stopped

      case unquote(input) do
        :keyboard -> send_keys_sync(ctx, "<Esc><CR>")
        :click -> send_gui_action(ctx, {:agent_continue_turn, interrupted})
      end

      await_working(ctx)
      assert %{stop_target: resumed, continue_target: nil} = Session.editor_snapshot(session)
      assert {^record, _new_request} = resumed
      refute resumed == interrupted
      assert user_messages(session) == ["go"]
      assert Session.get_queued_messages(session) == {[], ["later"]}
      assert prompt(ctx) == unquote(draft)

      assert :ok = Session.stop_turn(session, resumed)
      assert {:error, :stale_turn} = Session.continue_stopped(session, interrupted)
      assert Session.status(session) == :stopped
    end
  end

  for {label, to_front} <- [
        {"the conversation's split is closed", "<Esc><Esc><SPC>av"},
        {"SPC a a went back to the file", "<Esc><Esc><SPC>aa"},
        {"the file's window has the focus", "<Esc><Esc><C-w>h"}
      ] do
    test "SPC a s stops the working turn when #{label}", %{editor_ctx: ctx, session: session} do
      send_keys_sync(ctx, "go")
      send_key_sync(ctx, 13, @cmd)
      await_working(ctx)

      send_keys_sync(ctx, unquote(to_front))
      send_keys_sync(ctx, "<SPC>as")

      wait_until(ctx, fn _state -> Session.status(session) == :stopped end,
        message: "expected SPC a s to stop the turn from a file buffer"
      )

      refute minibuffer(ctx) =~ "no longer active"

      wait_until(ctx, fn _state -> modeline(ctx) =~ "Minga stopped" end,
        message: "expected the modeline of the file in front to say Minga stopped"
      )

      # One fact, one value: the file's modeline, the conversation's row in the Spaces bar and
      # its task (the tasks drawer's row) speak the same state.
      assert spoken_states(ctx, session) == %{modeline: :stopped, space: :stopped, task: :stopped}
    end
  end

  test "Ctrl+U deletes to the start of the line and no longer scrolls while typing", %{
    editor_ctx: ctx
  } do
    send_keys_sync(ctx, "keep<CR>drop this")
    send_keys_sync(ctx, "<C-u>")
    assert prompt(ctx) == "keep\n"

    send_keys_sync(ctx, "again<C-w>")
    assert prompt(ctx) == "keep\n"
  end

  test "q in the composer's Normal mode is Vim's; q in chat navigation closes the split", %{
    editor_ctx: ctx
  } do
    send_keys_sync(ctx, "<Esc>qa")
    state = editor_state(ctx)
    assert state.workspace.agent_ui.panel.input_focused
    assert {true, "a"} = Minga.Editing.macro_recording_status(state)
    assert Runtime.active_tab(state.shell_runtime).kind == :agent

    send_keys_sync(ctx, "q<Esc>q")
    state = editor_state(ctx)
    refute state.workspace.agent_ui.panel.input_focused
    refute Runtime.active_tab(state.shell_runtime).kind == :agent
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

  # A saved conversation queues through its durable draft, so the composer
  # clears once the Session confirms the queued input. The key is pressed right
  # after typing, as a fast typist does (#4260).
  defp queue(ctx, text) do
    send_keys_sync(ctx, text)
    send_key_sync(ctx, 13, @alt)
    await_prompt(ctx, "")
  end

  defp await_prompt(ctx, expected) do
    wait_until(ctx, fn _state -> prompt(ctx) == expected end,
      max_attempts: 200,
      message: "expected the composer to read #{inspect(expected)}"
    )
  end

  defp await_working(ctx) do
    wait_until(
      ctx,
      fn state ->
        agent = MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)

        # Queue and Stop act on the turn the composer shows, so wait for its targets too.
        agent.runtime.status in [:thinking, :tool_executing] and agent.queue_target != nil and
          agent.stop_target != nil
      end,
      max_attempts: 200,
      message: "expected Minga to be working"
    )
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

  # The state each surface speaks for `session`'s conversation, in the design tokens' words.
  defp spoken_states(ctx, session) do
    state = editor_state(ctx)
    {:ok, task} = Tasks.fetch(state.agent_connection.tasks, session)
    data = state |> StatusBarData.from_state() |> StatusBarData.to_modeline_data()
    %{left: left, right: right} = Modeline.gui_segments(data, state.appearance.theme)
    minga = Enum.find(left ++ right, &(&1.id == :minga))

    space =
      state
      |> ChromeState.from_editor_state()
      |> Map.fetch!(:workspaces)
      |> Enum.find(&(&1.kind == :agent))

    %{
      modeline: minga.state,
      space: Tokens.agent_status_state(space.status),
      task: Tasks.Entry.state(task)
    }
  end

  defp prompt(ctx),
    do: MingaEditor.Agent.PromptBuffer.input_text(editor_state(ctx).workspace.agent_ui)

  defp user_messages(session) do
    for {:user, text} <- Session.messages(session), do: text
  end
end
