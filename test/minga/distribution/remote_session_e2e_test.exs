defmodule Minga.Distribution.RemoteSessionE2ETest do
  @moduledoc """
  End-to-end verification of detachable agent sessions over Erlang distribution
  (proposal #955, Phase 1). Boots a headless runtime on a real peer node (the
  "server"), then drives the full GUI-side flow from the local node:

    * start a session on the server via cross-node call
    * subscribe to the remote session pid and receive agent events across nodes
    * read full history across nodes
    * detach (subscriber dies) and confirm the session survives on the server
    * reattach and confirm state was preserved

  This proves the distribution transport already delivers Phase 1 without any
  custom TCP protocol or remote-session-proxy.

  Tagged `:distributed` and excluded by default (it boots a real peer node and
  needs Erlang distribution / epmd). Run it explicitly:

      mix test --include distributed test/minga/distribution/remote_session_e2e_test.exs
  """
  # Boots real peer nodes and uses epmd, both global OS/distribution resources.
  use Minga.Test.DistributedCase, async: false

  alias Minga.Buffer
  alias Minga.Distribution.Events.NodeConnectedEvent
  alias MingaAgent.DraftSnapshot
  alias MingaAgent.RemoteAPI
  alias MingaAgent.Session
  alias MingaAgent.SessionListing
  alias MingaAgent.SessionManager
  alias MingaAgent.SessionMetadata
  alias MingaEditor.Agent.DraftSave
  alias MingaEditor.Agent.DraftWorkflow
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.QuestionResponse
  alias MingaEditor.Agent.SlashCommand
  alias MingaEditor.Agent.UIState
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Handlers.EventDispatcher
  alias MingaEditor.Remote.SessionClient
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace

  @moduletag :distributed

  @stub Minga.Test.StubProvider

  # Real two-node tests need epmd. Ensure it is up before any node starts, so
  # the suite is self-sufficient regardless of how the VM was launched.
  setup_all do
    System.cmd("epmd", ["-daemon"])
    :ok
  end

  setup do
    name = :"minga_server_e2e_#{System.unique_integer([:positive])}@127.0.0.1"
    {:ok, peer} = start_peer_node(name)
    on_exit(fn -> stop_peer_node(peer) end)

    # Make the peer a headless Minga "server": load app + config, point its
    # config dir at a temp location, then boot the headless supervision tree.
    config_home = Path.join(System.tmp_dir!(), "minga-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(config_home, "minga"))
    on_exit(fn -> File.rm_rf(config_home) end)

    # Load the app, copy this VM's :minga config onto the peer, and point its
    # config dir at a temp location, all before starting the application.
    :erpc.call(peer.node, Application, :load, [:minga])

    :ok =
      :erpc.call(peer.node, Application, :put_all_env, [[minga: Application.get_all_env(:minga)]])

    :erpc.call(peer.node, System, :put_env, [
      [{"XDG_CONFIG_HOME", config_home}, {"XDG_DATA_HOME", Path.join(config_home, "data")}]
    ])

    # The peer never ran test_helper.exs, so seed the ETS stub tables the boot
    # path touches and silence noisy background work.
    :erpc.call(peer.node, Minga.Git.Stub, :ensure_table, [])
    :erpc.call(peer.node, Minga.Tool.Installer.Stub, :ensure_table, [])

    # Boot the full app under the application master (durable, unlike a
    # Supervisor.start_link owned by the ephemeral erpc caller). In the test
    # config start_editor? is false, so this is a headless server: Foundation +
    # Services + Agent, no Port/renderer.
    {:ok, _started} = :erpc.call(peer.node, Application, :ensure_all_started, [:minga])

    %{server: peer.node}
  end

  test "headless server runs an agent session with no GUI attached (AC1)", %{server: server} do
    {:ok, session_id, remote_pid} =
      :erpc.call(server, SessionManager, :start_session, [[provider: @stub]])

    assert is_binary(session_id)
    assert node(remote_pid) == server, "session must live on the server node, not the client"

    # No local subscriber exists. The session is fully functional anyway.
    assert :erpc.call(server, Process, :alive?, [remote_pid])
  end

  test "client subscribes across nodes and receives agent events live (AC3)", %{server: server} do
    {:ok, _id, remote_pid} =
      :erpc.call(server, SessionManager, :start_session, [[provider: @stub]])

    # The local (client) process subscribes to the remote session pid directly.
    :ok = Session.subscribe(remote_pid, self())

    # Drive an event on the server. broadcast/2 is a plain send/2 to subscriber
    # pids, which is network-transparent: the event crosses the node boundary.
    Session.add_system_message(remote_pid, "hello from the server")

    assert_receive {:agent_event, ^remote_pid, :messages_changed}, 2_000

    # Full history is readable across nodes (GenServer.call to a remote pid).
    messages = Session.messages(remote_pid)
    assert Enum.any?(messages, &match?({:system, "hello from the server", _}, &1))
  end

  test "session survives client disconnect and is still listed (AC2 + AC4)", %{server: server} do
    {:ok, session_id, remote_pid} =
      :erpc.call(server, SessionManager, :start_session, [[provider: @stub]])

    Session.add_system_message(remote_pid, "work done while you were away")

    # Simulate a GUI that subscribes, then dies (laptop closed / wifi lost).
    subscriber = spawn(fn -> receive do: (:stop -> :ok) end)
    ref = Process.monitor(subscriber)

    assert :ok = Session.subscribe(remote_pid, subscriber)
    Process.exit(subscriber, :kill)
    assert_receive {:DOWN, ^ref, :process, ^subscriber, _}, 1_000

    # The session keeps running on the server with zero subscribers...
    assert :erpc.call(server, Process, :alive?, [remote_pid])

    # ...and is still enumerable for a reconnecting GUI to find.
    sessions = :erpc.call(server, SessionManager, :list_sessions, [])

    assert Enum.any?(sessions, fn
             %SessionListing{
               id: ^session_id,
               pid: ^remote_pid,
               details: {:available, %SessionMetadata{id: ^session_id}}
             } ->
               true

             _listing ->
               false
           end)
  end

  test "brokered attach enforces one driver while viewers still receive events", %{server: server} do
    {:ok,
     %{
       session_id: session_id,
       pid: remote_pid,
       token: token,
       metadata: %SessionMetadata{id: session_id} = metadata,
       details: {:available, metadata}
     }} =
      :erpc.call(server, RemoteAPI, :start_session, [[provider: @stub]])

    assert {:ok, %{role: :driver}} =
             :erpc.call(server, RemoteAPI, :attach, [session_id, token, self(), [role: :driver]])

    test_pid = self()

    viewer =
      spawn(fn ->
        attach_result =
          :erpc.call(server, RemoteAPI, :attach, [
            session_id,
            token,
            self(),
            [role: :driver]
          ])

        receive do
          {:agent_event, ^remote_pid, {:credentials_status, _configured?}} ->
            send(test_pid, {:viewer_attached, attach_result})
        end

        receive do
          {:agent_event, ^remote_pid, :messages_changed} ->
            send(test_pid, {:viewer_event, :messages_changed})
        end
      end)

    assert_receive {:viewer_attached, {:ok, %{role: :viewer}}}, 1_000

    assert {:error, :not_driver} =
             :erpc.call(server, RemoteAPI, :send_prompt, [
               session_id,
               token,
               viewer,
               "viewer prompt"
             ])

    Session.add_system_message(remote_pid, "event visible to all clients")
    assert_receive {:agent_event, ^remote_pid, :messages_changed}, 2_000
    assert_receive {:viewer_event, :messages_changed}, 2_000

    Process.exit(viewer, :kill)
  end

  test "reattach after disconnect sees preserved state (AC4)", %{server: server} do
    {:ok, _id, remote_pid} =
      :erpc.call(server, SessionManager, :start_session, [[provider: @stub]])

    Session.add_system_message(remote_pid, "message before disconnect")

    # First client attaches and detaches.
    {:ok, agent} = Agent.start_link(fn -> :ok end)
    :ok = Session.subscribe(remote_pid, agent)
    :ok = Agent.stop(agent)

    # Reconnecting client re-subscribes and snapshots history. The message
    # produced before the disconnect is still there: state lived on the server.
    :ok = Session.subscribe(remote_pid, self())
    messages = Session.messages(remote_pid)
    assert Enum.any?(messages, &match?({:system, "message before disconnect", _}, &1))

    # And the reattached client receives new live events across the node boundary.
    Session.add_system_message(remote_pid, "message after reconnect")
    assert_receive {:agent_event, ^remote_pid, :messages_changed}, 2_000

    assert Enum.any?(
             Session.messages(remote_pid),
             &match?({:system, "message after reconnect", _}, &1)
           )
  end

  for restart? <- [false, true] do
    @tag restart_session: restart?
    test "inactive queue recovery and retirement after reconnect, restart=#{restart?}", %{
      server: server,
      restart_session: restart?
    } do
      assert {:ok, %{session_id: record, pid: session, token: token}} =
               SessionClient.start_session(server, provider: Minga.Test.SessionSlowMockProvider)

      first = attach_driver(server, record, session, token)
      assert :ok = Session.send_prompt(session, "Hold the active turn")

      assert {:ok, {^record, _, sequence} = target} =
               :erpc.call(server, Session, :queue_target, [session, record])

      text = "Retain one queued instruction"
      submission = String.duplicate("q", 24)
      draft = %DraftSnapshot{text: text, cursor: {0, 0}, attachments: [], paste_blocks: []}
      assert {:ok, 1} = SessionClient.composer({session, record}, first, {:save, 0, draft})

      assert {:ok, receipt} =
               SessionClient.composer(
                 {session, record},
                 first,
                 {:queue, target, :follow_up, {1, submission, [], text}, text}
               )

      %{connection: connection} = Session.editor_snapshot(session)
      assert {:ok, ui} = PromptBuffer.restore_draft(%UIState{}, draft)
      buffer = ui.panel.prompt_buffer
      marker = Buffer.inspection_marker(buffer)
      original = make_ref()

      save =
        DraftSave.loaded(
          DraftSave.loading({session, record}, buffer, make_ref(), marker),
          1,
          marker,
          draft
        )

      assert {:ok, 1, pending} =
               DraftSave.begin_queue(save, original, marker, {sequence, submission, :follow_up})

      ui = ui |> UIState.project_connection(connection) |> UIState.project_draft_save(pending)

      {tabs, workspace} =
        TabBar.add_workspace(TabBar.new(Tab.new_file(1, "Other")), "Remote", session)

      owner = workspace.id

      tabs =
        tabs
        |> TabBar.accept_workspace(
          Workspace.put_remote_session(workspace, "fixture", record, :connected, 0)
        )
        |> TabBar.set_workspace_agent_ui(owner, ui)

      refute TabBar.active_workspace_id(tabs) == owner
      tasks = start_supervised!(Task.Supervisor)
      scheduler = start_supervised!({EffectScheduler, task_supervisor: tasks})
      shell = TraditionalState.install_tab_bar(%TraditionalState{}, tabs)

      state = %EditorState{
        workspace: %MingaEditor.Session.State{},
        shell_runtime: Runtime.new(Runtime.default_entry(), shell),
        effect_scheduler: scheduler
      }

      state =
        DraftWorkflow.handle_result(
          state,
          session,
          record,
          owner,
          original,
          {:error, {:remote_unavailable, :queue_receipt_unconfirmed}}
        )

      assert :ok = :erpc.call(server, RemoteAPI, :detach, [record, token, first])

      {state, session, token, second} =
        reconnect_draft_owner(state, server, record, session, token, restart?)

      assert_receive {:composer_draft_result, ^session, ^record, {^owner, lookup},
                      {:ok, ^receipt}},
                     2_000

      assert lookup != original
      assert :ok = :erpc.call(server, RemoteAPI, :detach, [record, token, second])
      state = DraftWorkflow.handle_result(state, session, record, owner, lookup, {:ok, receipt})

      assert_receive {:composer_draft_result, ^session, ^record, {^owner, lost},
                      {:error, :not_driver}},
                     2_000

      state =
        DraftWorkflow.handle_result(state, session, record, owner, lost, {:error, :not_driver})

      {state, session, token, third} =
        reconnect_draft_owner(state, server, record, session, token, restart?)

      assert_receive {:composer_draft_result, ^session, ^record, {^owner, retired}, :ok}, 2_000
      assert retired != lost
      state = DraftWorkflow.handle_result(state, session, record, owner, retired, :ok)
      assert {:ok, _state} = DraftWorkflow.before_close(state, owner)
      assert {[], [^text]} = Session.get_queued_messages(session)

      assert {:error, :queue_receipt_unconfirmed} =
               SessionClient.composer(
                 {session, record},
                 third,
                 {:reconcile_queue, sequence, submission, 1}
               )

      # Renew the driver before the in-flight autosave's failure reaches the Editor.
      assert :ok = :erpc.call(server, RemoteAPI, :detach, [record, token, third])
      newer = "Keep new inactive draft text"
      Buffer.insert_text(buffer, newer)
      state = DraftWorkflow.edited(state, buffer)
      assert_receive {:composer_draft_due, ^owner, timer}, 1_000
      state = DraftWorkflow.due(state, owner, timer)

      assert_receive {:composer_draft_result, ^session, ^record, {^owner, write},
                      {:error, :not_driver}},
                     2_000

      {_, renewed} = fourth = attach_driver(server, record, session, token)

      state =
        state
        |> QuestionResponse.bind_remote_attachment(session, renewed)
        |> DraftWorkflow.driver_reattached(session)

      state =
        DraftWorkflow.handle_result(state, session, record, owner, write, {:error, :not_driver})

      assert_receive {:composer_draft_due, ^owner, retry}, 1_000
      state = DraftWorkflow.due(state, owner, retry)
      assert_receive {:composer_draft_result, ^session, ^record, {^owner, saved}, {:ok, 3}}, 2_000
      _state = DraftWorkflow.handle_result(state, session, record, owner, saved, {:ok, 3})

      assert {:ok, 3, %DraftSnapshot{text: ^newer}} =
               SessionClient.composer({session, record}, fourth, :read)

      assert {[], [^text]} = Session.get_queued_messages(session)
    end
  end

  defp reconnect_draft_owner(state, server, record, previous, token, restart?) do
    {session, token} =
      if restart? do
        assert :ok = :erpc.call(server, SessionManager, :stop_session, [record])

        assert {:ok, %{session_id: ^record, token: token, pid: replacement}} =
                 SessionClient.start_session(server,
                   session_id: record,
                   provider: Minga.Test.SessionSlowMockProvider
                 )

        refute replacement == previous
        assert :ok = :erpc.call(server, Session, :load_session, [replacement, record])
        {replacement, token}
      else
        {previous, token}
      end

    event = %NodeConnectedEvent{
      server_name: "fixture",
      node: server,
      connected_at: DateTime.utc_now()
    }

    state = EventDispatcher.dispatch(state, :node_connected, event, nil)
    assert_receive {:agent_question_attachment, ^session, receipt}, 2_000

    state =
      state
      |> QuestionResponse.bind_remote_attachment(session, receipt)
      |> DraftWorkflow.driver_reattached(session)

    {state, session, token, {self(), receipt}}
  end

  test "a peer without saved-composer support still accepts active-turn Send", %{server: server} do
    assert {:ok, %{session_id: record, pid: session, token: token}} =
             SessionClient.start_session(server, provider: Minga.Test.SessionSlowMockProvider)

    _authority = attach_driver(server, record, session, token)
    assert :ok = Session.send_prompt(session, "Hold the active turn")
    assert {:ok, target} = :erpc.call(server, Session, :queue_target, [session, record])
    %{connection: connection} = Session.editor_snapshot(session)
    text = "Send through the compatible broker path"
    draft = %DraftSnapshot{text: text, cursor: {0, 0}, attachments: [], paste_blocks: []}
    assert {:ok, ui} = PromptBuffer.restore_draft(%UIState{}, draft)
    ui = UIState.project_connection(ui, %{connection | remote_composer_drafts?: false})

    tab = Tab.new_agent(1, "Remote")
    {tabs, workspace} = TabBar.add_workspace(TabBar.new(tab), "Remote", session)

    shell =
      TraditionalState.install_tab_bar(
        %TraditionalState{},
        TabBar.move_tab_to_workspace(tabs, tab.id, workspace.id)
      )

    shell =
      TraditionalState.replace_agent(
        shell,
        AgentState.project_queue_target(TraditionalState.agent(shell), session, target)
      )

    state = %EditorState{
      workspace: MingaEditor.Session.State.set_agent_ui(%MingaEditor.Session.State{}, ui),
      shell_runtime: Runtime.new(Runtime.default_entry(), shell)
    }

    assert :ordinary = DraftWorkflow.queue(state, :steering, text)
    assert {:queued, :steering} = SessionClient.send_prompt(session, text)
    assert {[^text], []} = Session.get_queued_messages(session)
  end

  defp attach_driver(server, record, session, token) do
    assert {:ok, %{role: :driver}} = SessionClient.attach_driver(server, record, token, 0, self())
    assert_receive {:agent_question_attachment, ^session, receipt}, 2_000
    {self(), receipt}
  end

  test "remote OAuth callback failure does not expose the pasted description", %{server: server} do
    {:ok, %{session_id: id, token: token, pid: session}} =
      SessionClient.start_session(server, provider: @stub)

    {:ok, %{role: :driver}} = SessionClient.attach_driver(server, id, token, 0, self())
    {:ok, _url, ref} = SessionClient.begin_oauth(session)

    tab = Tab.new_agent(1, "Agent")
    {tab_bar, workspace} = tab |> TabBar.new() |> TabBar.add_workspace("Agent", session)
    tab_bar = TabBar.move_tab_to_workspace(tab_bar, tab.id, workspace.id)
    shell = TraditionalState.install_tab_bar(%TraditionalState{}, tab_bar)

    state = %EditorState{
      workspace: %MingaEditor.Session.State{},
      shell_runtime: Runtime.new(Runtime.default_entry(), shell)
    }

    callback =
      "http://localhost:1455/auth/callback?error=access_denied&error_description=callback-sentinel"

    assert {:ok, _state} = SlashCommand.execute(state, "/login --complete #{ref} #{callback}")
    assert_receive {:agent_event, ^session, :messages_changed}, 2_000

    failures = for {:system, text, :error} <- Session.messages(session), do: text

    assert "Login failed. Start a new login and paste the callback URL from that attempt." in failures

    refute Enum.any?(failures, &String.contains?(&1, "callback-sentinel"))
  end
end
