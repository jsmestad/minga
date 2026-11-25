defmodule MingaEditor.Journeys.ComposerKeysTest do
  @moduledoc """
  The composer behaves like a Vim buffer: it opens in Insert, `↩` adds a newline while typing, and Normal-mode `↩` or `⌘↩` sends. `⌥↩` queues, `SPC a s` and `⌘.` stop and keep the queue, and `q` closes the split only outside the composer (docs/design/keys.md, Composer; #4055).

  The slow mock provider starts a turn and never finishes it, so a sent prompt leaves Minga working until it is stopped.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Config.Options
  alias MingaAgent.Session
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Shell.Runtime

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
    assert prompt(ctx) == ""
    assert user_messages(session) == ["first\nsecond"]
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
    settle_draft(ctx)
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

  # A saved conversation queues through its durable draft, so the composer
  # clears once the Session confirms the queued input.

  # A saved conversation queues (and steers) only a draft it has saved; typing
  # arms a save, so wait for it to settle first (an unsettled draft is kept).
  defp queue(ctx, text) do
    send_keys_sync(ctx, text)
    settle_draft(ctx)
    send_key_sync(ctx, 13, @alt)
    await_prompt(ctx, "")
  end

  defp settle_draft(ctx) do
    wait_until(
      ctx,
      fn state ->
        match?(
          %MingaEditor.Agent.DraftSave{request: {:ready, _, _}, timer: nil},
          state.workspace.agent_ui.draft_save
        )
      end,
      max_attempts: 200,
      message: "expected the typed draft to be saved"
    )
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

  defp prompt(ctx),
    do: MingaEditor.Agent.PromptBuffer.input_text(editor_state(ctx).workspace.agent_ui)

  defp user_messages(session) do
    for {:user, text} <- Session.messages(session), do: text
  end
end
