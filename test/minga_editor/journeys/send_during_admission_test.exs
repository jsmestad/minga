defmodule MingaEditor.Journeys.SendDuringAdmissionTest do
  @moduledoc """
  A first message whose provider is still counting its fixed instructions is not refused (#4296).

  The Session runs the native provider with the Apple on-device selection, and the Apple tokenizer is replaced by a counter. A prefix that contains the uncounted rule is counted only when the test lets it, so a count can be held for as long as a journey needs: nothing here waits on a clock.

  While the count is held, the Session is admitting the message. The editor shows that as Minga working, a second press queues behind the first, and Stop ends the admission and keeps the draft.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Config.Options
  alias MingaAgent.Credentials
  alias MingaAgent.Session
  alias MingaAgent.Test.ModelSelectionFixture
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Shell.Runtime

  @moduletag :tmp_dir
  @uncounted_rule "A rule nobody has counted"
  @capabilities %Capabilities{frontend_type: :native_gui, semantic_ui: true}
  @ctrl 0x02
  @cmd 0x08

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "project")
    File.mkdir_p!(Path.join(root, ".git"))
    File.write!(Path.join(root, "AGENTS.md"), "A first rule.\n")
    path = Path.join(root, "journey.txt")
    File.write!(path, "A file beside the conversation")
    options = start_supervised!(Supervisor.child_spec({Options, name: nil}, id: make_ref()))

    env = Map.new(Credentials.known_providers(), &{Credentials.env_var_for(&1), nil})
    credential_opts = [config_dir: dir, oauth_path: Path.join(dir, "oauth.json"), env: env]
    owner = self()

    # A count is held by what it counts, not by when it runs: only a prefix with the uncounted
    # rule waits for the test, so a count the Session started on its own cannot slip past.
    counter = fn texts, candidates, _tools, _reserve ->
      held? = Enum.any?(texts, &(&1 =~ @uncounted_rule))
      if held?, do: send(owner, {:counting, self()})

      counts =
        for candidate <- candidates do
          candidate |> Enum.map_join("\n\n", &Enum.at(texts, &1)) |> byte_size() |> div(4)
        end

      receive do
        :count -> {:ok, %{counts: counts, context: 4_096}}
        {:fail, reason} -> {:error, reason}
      after
        if(held?, do: :infinity, else: 0) -> {:ok, %{counts: counts, context: 4_096}}
      end
    end

    # The model never answers, so an admitted turn stays working.
    silent_model = fn _model, _messages, _opts ->
      receive do
        :never -> {:error, :unreachable}
      end
    end

    ctx =
      start_editor("A file beside the conversation",
        file_path: path,
        project_root: root,
        shell: :traditional,
        capabilities: @capabilities,
        options_server: options,
        agent_provider_module: MingaAgent.Providers.Native,
        agent_provider_opts: [
          credential_opts: credential_opts,
          apple_counter: counter,
          llm_client: silent_model,
          model_resolver_opts:
            ModelSelectionFixture.resolver_opts()
            |> Keyword.delete(:credential_snapshot)
            |> Keyword.put(:apple_availability_fn, fn -> {:ok, 4_096} end)
        ],
        agent_arrival_budget_ms: 4_000
      )

    send_keys_sync(ctx, "<SPC>av")
    session = await_session(ctx)

    # No provider has credentials here, so the session starts without a model; the on-device
    # model is picked the way the model picker picks it.
    assert :ok = Session.set_model(session, "apple:system")
    await_model(ctx)

    %{editor_ctx: ctx, session: session, root: root}
  end

  test "two Enters on a count that is still running: the first sends, the second queues, nothing is refused",
       %{editor_ctx: ctx, session: session, root: root} do
    cold(root)
    send_keys_sync(ctx, "first<Esc><CR>")
    assert_receive {:counting, counting}, 5_000

    # The message is being admitted: Minga reads as working, and the composer keeps the text.
    await_working(ctx)
    assert modeline(ctx) =~ "Minga working"
    assert prompt(ctx) == "first"
    assert user_messages(session) == []

    send_keys_sync(ctx, "Asecond<Esc><CR>")
    refute minibuffer(ctx) =~ "The Agent turn changed"

    send(counting, :count)

    eventually(ctx, "expected the first message to be sent when the count ended", fn _state ->
      user_messages(session) == ["first"]
    end)

    eventually(
      ctx,
      "expected the second press to be queued behind the first message",
      fn _state -> Session.get_queued_messages(session) == {["second"], []} end
    )

    await_prompt(ctx, "")
    refute minibuffer(ctx) =~ "The Agent turn changed"
    refute minibuffer(ctx) =~ "not sent"
    assert modeline(ctx) =~ "Minga working"
  end

  for {label, stop} <- [
        {"SPC a s", "<SPC>as"},
        {"Ctrl+C", :ctrl_c},
        {"Cmd+.", :cmd_period},
        {"the Stop control", :stop_control}
      ] do
    test "#{label} during admission stops it, keeps the draft, and the next send goes at once", %{
      editor_ctx: ctx,
      session: session,
      root: root
    } do
      cold(root)
      send_keys_sync(ctx, "first<Esc><CR>")
      assert_receive {:counting, counting}, 5_000
      await_working(ctx)

      case unquote(stop) do
        :ctrl_c -> send_key_sync(ctx, ?c, @ctrl)
        :cmd_period -> send_key_sync(ctx, ?., @cmd)
        :stop_control -> press_stop_control(ctx)
        keys -> send_keys_sync(ctx, keys)
      end

      eventually(ctx, "expected #{unquote(label)} to stop the admission", fn _state ->
        Session.status(session) == :stopped
      end)

      eventually(ctx, "expected the modeline to say Minga stopped", fn _state ->
        modeline(ctx) =~ "Minga stopped"
      end)

      assert user_messages(session) == []
      assert prompt(ctx) == "first"
      assert minibuffer(ctx) =~ "Stopped before the message was sent. Your draft is preserved."

      # The count was not stopped with the admission. Its result admits the next press at once.
      send(counting, :count)
      monitor = Process.monitor(counting)
      assert_receive {:DOWN, ^monitor, :process, ^counting, _reason}, 5_000

      send_keys_sync(ctx, "<CR>")

      eventually(ctx, "expected the kept draft to be sent on the next press", fn _state ->
        user_messages(session) == ["first"]
      end)

      refute_received {:counting, _again}
    end
  end

  test "a count that fails ends calmly: the draft is kept and one line says what to do", %{
    editor_ctx: ctx,
    session: session,
    root: root
  } do
    cold(root)
    send_keys_sync(ctx, "first<Esc><CR>")
    assert_receive {:counting, counting}, 5_000
    await_working(ctx)

    send(counting, {:fail, :apple_count_timeout})

    eventually(ctx, "expected one line that says the count did not finish", fn _state ->
      minibuffer(ctx) =~ "did not finish counting"
    end)

    assert minibuffer(ctx) =~ "Try again"
    assert prompt(ctx) == "first"
    assert user_messages(session) == []
    refute modeline(ctx) =~ "Minga working"
  end

  # A changed instructions file is a prefix the provider has not counted yet.
  defp cold(root) do
    File.write!(
      Path.join(root, "AGENTS.md"),
      "#{@uncounted_rule}, #{System.unique_integer()}.\n"
    )
  end

  # The Stop control sends the turn it shows, as a click on it does.
  defp press_stop_control(%{editor: editor} = ctx) do
    {_session, target} =
      MingaEditor.Shell.Traditional.State.agent(editor_state(ctx).shell_runtime.state).stop_target

    send(editor, {:minga_input, {:gui_action, {:agent_stop_turn, target}}})
    :sys.get_state(editor)
    :ok
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
                connection: %{target: %{session: ^session}},
                draft_save: %{target: {^session, _}, request: {:ready, _, _}}
              },
              state.workspace.agent_ui
            )
        end,
        max_attempts: 500,
        interval_ms: 20,
        message: "expected SPC a v to attach a session with its draft loaded"
      )

    Runtime.active_session(state.shell_runtime)
  end

  defp await_model(ctx) do
    wait_until(
      ctx,
      fn state ->
        ui = state.workspace.agent_ui
        ui.connection.provider_phase == :running and is_binary(ui.panel.model_name)
      end,
      max_attempts: 300,
      message: "expected a running provider with the Apple on-device model shown"
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

  defp await_prompt(ctx, expected) do
    eventually(ctx, "expected the composer to read #{inspect(expected)}", fn _state ->
      prompt(ctx) == expected
    end)
  end

  # A Session round trip can outlast the default wait on a busy machine.
  defp eventually(ctx, message, condition),
    do: wait_until(ctx, condition, max_attempts: 300, interval_ms: 20, message: message)

  defp prompt(ctx),
    do: MingaEditor.Agent.PromptBuffer.input_text(editor_state(ctx).workspace.agent_ui)

  defp user_messages(session) do
    for {:user, text} <- Session.messages(session), do: text
  end
end
