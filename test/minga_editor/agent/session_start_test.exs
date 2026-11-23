defmodule MingaEditor.Agent.SessionStartTest do
  @moduledoc """
  The Editor-side contract of a non-blocking Agent session start (#3934).

  The test process plays the Editor: it holds the state, receives the start's attach event and the manager's reply in its own mailbox, and feeds them through `MingaEditor.Agent.SessionStart` exactly as `MingaEditor.handle_info/2` does.
  """

  use ExUnit.Case, async: true

  alias Minga.Test.AgentSessionStart
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.SessionStart
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.AgentConnection
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar

  describe "opening the Agent" do
    test "shows the starting composer without waiting for the session manager" do
      manager = silent_manager()
      opened = state(manager) |> AgentCommands.new_agent_session()

      assert_receive {:start_requested, ^manager, opts}
      assert [{subscriber, [questions?: true]}] = opts[:subscribers]
      assert subscriber == self()
      assert is_reference(opts[:start_token])

      assert Runtime.active_tab_kind(opened.shell_runtime) == :agent
      assert Runtime.active_session(opened.shell_runtime) == nil
      assert opened.workspace.agent_ui.chat_lifecycle == :starting

      assert %{visible?: true, lifecycle: :starting} =
               Minga.Test.AgentWorkflowDriver.chat_model(opened)
    end

    test "a second open while the first start is in flight sends no second request" do
      manager = silent_manager()
      opened = state(manager) |> AgentCommands.new_agent_session()
      assert_receive {:start_requested, ^manager, _opts}

      again = MingaEditor.Commands.AgentSession.start_agent_session(opened)
      refute_receive {:start_requested, ^manager, _opts}, 50
      assert map_size(again.agent_connection.session_starts) == 1
    end

    test "a key typed before the open edits the file and keys after it fill the starting draft" do
      before = state(silent_manager())
      file = before.workspace.buffers.active
      before = MingaEditor.Input.Router.route_key(before, ?x, 0)
      assert Minga.Buffer.content(file) == "ine one\nline two\nline three"

      opened = AgentCommands.new_agent_session(before)

      typed =
        Enum.reduce(~c"hi", opened, fn key, state ->
          MingaEditor.Input.Router.route_key(state, key, 0)
        end)

      assert PromptBuffer.prompt_text(typed.workspace.agent_ui) == "hi"
      assert typed.workspace.agent_ui.chat_lifecycle == :starting
      assert Minga.Buffer.content(file) == "ine one\nline two\nline three"
    end
  end

  describe "a start from a file tab with no Agent tab" do
    test "two starts create one Agent workspace and send one request" do
      manager = silent_manager()
      first = state(manager) |> AgentSession.start_agent_session()
      assert_receive {:start_requested, ^manager, _opts}

      second = AgentSession.start_agent_session(first)
      refute_receive {:start_requested, ^manager, _opts}, 50

      tabs = second.shell_runtime.state.tab_bar
      assert [%{id: workspace_id}] = Enum.filter(tabs.workspaces, &(&1.kind == :agent))
      assert TabBar.active_workspace_id(tabs) == 0
      assert [%{workspace: ^workspace_id}] = Map.values(second.agent_connection.session_starts)
      assert [%Tab{kind: :agent}] = TabBar.tabs_in_workspace(tabs, workspace_id)
    end

    test "the boot start ends its starting state when the user switches to the workspace" do
      _catalog = LLMDB.providers()
      ingest = start_supervised!({MingaEditor.Agent.Ingest, editor: self()})

      booted =
        state(MingaAgent.SessionManager)
        |> with_agent_chat_window()
        |> then(fn state ->
          %{
            state
            | agent_connection: AgentConnection.connect_ingest(state.agent_connection, ingest)
          }
        end)
        |> MingaEditor.AgentLifecycle.maybe_start_session()
        |> AgentSessionStart.settle()

      tabs = booted.shell_runtime.state.tab_bar

      assert [%{id: workspace_id, payload: %{session: session}}] =
               Enum.filter(tabs.workspaces, &(&1.kind == :agent))

      on_exit(fn -> MingaAgent.SessionManager.stop_session_by_pid(session) end)
      assert is_pid(session)
      assert TabBar.active_workspace_id(tabs) == 0
      assert [%Tab{id: agent_tab}] = TabBar.tabs_in_workspace(tabs, workspace_id)

      arrived = booted |> MingaEditor.TabWorkflow.switch(agent_tab) |> collect_arrival(session)
      assert Runtime.active_session(arrived.shell_runtime) == session
      assert {:conversation, ^session} = arrived.workspace.agent_ui.chat_lifecycle
    end
  end

  describe "failures keep the draft" do
    test "a start that does not reply before the deadline fails in its own tab" do
      opened = state(silent_manager()) |> AgentCommands.new_agent_session() |> draft("kept")
      [token] = Map.keys(opened.agent_connection.session_starts)

      failed = SessionStart.timeout(opened, token)

      assert {:failed, reason} = failed.workspace.agent_ui.chat_lifecycle
      assert reason =~ "did not start"
      assert TraditionalState.agent(failed.shell_runtime.state).error == reason
      assert PromptBuffer.prompt_text(failed.workspace.agent_ui) == "kept"
    end

    test "a manager error reply fails the starting tab and keeps the draft" do
      manager = spawn_link(fn -> reply_once({:error, :no_capacity}) end)
      opened = state(manager) |> AgentCommands.new_agent_session() |> draft("kept")

      failed = AgentSessionStart.settle(opened)

      assert {:failed, reason} = failed.workspace.agent_ui.chat_lifecycle
      assert reason =~ ":no_capacity"
      assert PromptBuffer.prompt_text(failed.workspace.agent_ui) == "kept"
      assert failed.agent_connection.session_starts == %{}
    end

    test "a manager that exits during the start fails the starting tab and keeps the draft" do
      manager = spawn(fn -> receive(do: ({:"$gen_call", _from, _request} -> exit(:crashed))) end)
      opened = state(manager) |> AgentCommands.new_agent_session() |> draft("kept")

      assert_receive {:DOWN, _ref, :process, ^manager, :crashed} = down, 1_000
      assert {:handled, failed} = SessionStart.response(opened, down)

      assert {:failed, reason} = failed.workspace.agent_ui.chat_lifecycle
      assert reason =~ ":crashed"
      assert PromptBuffer.prompt_text(failed.workspace.agent_ui) == "kept"
    end

    test "a session that starts after its deadline is stopped, not shown" do
      _catalog = LLMDB.providers()
      opened = state(MingaAgent.SessionManager) |> AgentCommands.new_agent_session()
      [token] = Map.keys(opened.agent_connection.session_starts)
      failed = SessionStart.timeout(opened, token)

      late = receive_reply()
      session = late_session(late)
      monitor = Process.monitor(session)
      {:handled, settled} = SessionStart.response(failed, late)

      assert_receive {:DOWN, ^monitor, :process, ^session, _reason}, 2_000
      assert Runtime.active_session(settled.shell_runtime) == nil
      assert settled.agent_connection.session_starts == %{}
    end
  end

  describe "readiness" do
    test "Send stays blocked with the starting status until the provider-ready broadcast" do
      _catalog = LLMDB.providers()
      opened = state(MingaAgent.SessionManager) |> AgentCommands.new_agent_session()
      bound = opened |> AgentSessionStart.settle() |> draft("hello")
      session = Runtime.active_session(bound.shell_runtime)
      on_exit(fn -> MingaAgent.SessionManager.stop_session_by_pid(session) end)
      assert is_pid(session)
      assert bound.workspace.agent_ui.chat_lifecycle == :starting

      blocked = AgentCommands.submit_prompt(bound)
      assert PromptBuffer.prompt_text(blocked.workspace.agent_ui) == "hello"
      assert blocked.shell_runtime.state.notice.message =~ "still starting"

      ready = deliver_until_running(blocked, session)
      assert {:conversation, ^session} = ready.workspace.agent_ui.chat_lifecycle
    end
  end

  @spec state(GenServer.server()) :: MingaEditor.State.t()
  defp state(manager) do
    state = TestHelpers.base_state(rendering: :disabled)

    state =
      MingaEditor.WorkspaceWorkflow.install_tab_bar(state, TabBar.new(Tab.new_file(1, "f.ex")))

    connection = AgentConnection.new(Minga.Test.StubProvider)
    %{state | agent_connection: %{connection | session_manager: manager}}
  end

  # A file tab whose layout already shows the Agent chat beside the file, as
  # when the editor boots into a saved Agent split.
  @spec with_agent_chat_window(MingaEditor.State.t()) :: MingaEditor.State.t()
  defp with_agent_chat_window(state) do
    windows = state.workspace.windows
    chat = MingaEditor.Window.new_agent_chat(windows.next_id, 24, 80)
    windows = %{windows | map: Map.put(windows.map, chat.id, chat), next_id: chat.id + 1}
    %{state | workspace: %{state.workspace | windows: windows}}
  end

  # Waits through the arrival's ordered capture, as the Editor does.
  @spec collect_arrival(MingaEditor.State.t(), pid()) :: MingaEditor.State.t()
  defp collect_arrival(state, session) do
    receive do
      {:agent_event, ^session, {:editor_arrival_ready, _, _}} = capture ->
        {:noreply, state} = MingaEditor.handle_info(capture, state)
        state

      {:agent_event, ^session, _earlier} ->
        collect_arrival(state, session)
    after
      5_000 -> flunk("expected the Agent arrival capture")
    end
  end

  @spec draft(MingaEditor.State.t(), String.t()) :: MingaEditor.State.t()
  defp draft(state, text) do
    MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
      state,
      PromptBuffer.set_prompt_text(state.workspace.agent_ui, text)
    )
  end

  # A manager that records the request and never replies.
  @spec silent_manager() :: pid()
  defp silent_manager do
    test = self()

    spawn_link(fn ->
      receive do
        {:"$gen_call", _from, {:start_session, opts}} ->
          send(test, {:start_requested, self(), opts})
          receive(do: (:never -> :ok))
      end
    end)
  end

  @spec reply_once(term()) :: :ok
  defp reply_once(reply) do
    receive do
      {:"$gen_call", from, {:start_session, _opts}} -> GenServer.reply(from, reply)
    end

    :ok
  end

  @spec receive_reply() :: term()
  defp receive_reply do
    receive do
      {[:alias | _ref], _reply} = reply -> reply
    after
      5_000 -> flunk("expected the session manager's reply")
    end
  end

  @spec late_session(term()) :: pid()
  defp late_session({_alias, {:ok, _id, session}}), do: session

  # Feeds the session's ordered events to the Editor until the provider runs.
  @spec deliver_until_running(MingaEditor.State.t(), pid()) :: MingaEditor.State.t()
  defp deliver_until_running(state, session) do
    receive do
      {:agent_event, ^session, event} ->
        {:noreply, state} = MingaEditor.handle_info({:agent_event, session, event}, state)

        case state.workspace.agent_ui.chat_lifecycle do
          {:conversation, ^session} -> state
          _starting -> deliver_until_running(state, session)
        end
    after
      5_000 -> flunk("expected the provider-ready connection broadcast")
    end
  end
end
