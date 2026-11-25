defmodule MingaEditor.Agent.SessionFollowUpTest do
  @moduledoc """
  Work that needs a newly started Agent session never makes the Editor wait for it (#3934 AC 2).

  The test process plays the Editor: it holds the state and feeds the session start's attach event, the manager's reply and the follow-up's reply through `MingaEditor.handle_info/2`. The session's provider start is held, so any call from the Editor to the session would wait behind it.
  """

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Minga.Test.AgentSessionStart
  alias Minga.Test.HeldStartProvider
  alias MingaAgent.Session
  alias MingaAgent.SessionStore
  alias MingaEditor.Agent.UIState.Presentation
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State.AgentConnection
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.Shell.Traditional.ModalWorkflow
  alias MingaEditor.Shell.Traditional.TasksDrawerWorkflow
  alias MingaEditor.State.ModalOverlay.Picker, as: PickerPayload
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.AgentSessionSource
  alias MingaEditor.UI.Picker.Item

  # The Editor's reply handling for a held session must finish well inside a
  # GenServer call timeout; a blocking call would take the full 5 s.
  @editor_budget_us 1_000_000

  setup %{tmp_dir: dir} do
    _catalog = LLMDB.providers()
    %{state: state(dir), dir: dir}
  end

  describe "a Restore into a started session" do
    test "does not wait for provider start and restores once the session answers", %{
      state: state,
      dir: dir
    } do
      saved = save_record(dir, "saved question")
      opened = AgentCommands.open_session(state, saved)
      provider = assert_provider_held()

      {elapsed, bound} = :timer.tc(fn -> AgentSessionStart.settle(opened) end)
      assert elapsed < @editor_budget_us
      session = Runtime.active_session(bound.shell_runtime)
      assert is_pid(session)

      HeldStartProvider.release(provider)
      restored = settle_through_editor(bound)

      assert inspect(Session.messages(session)) =~ "saved question"
      assert Runtime.active_tab_kind(restored.shell_runtime) == :agent
      # The restored view records the file the user opened it from, for the return trip.
      assert Presentation.return_target(bound.workspace.agent_ui.view.presentation) == nil

      assert %{active_tab_id: 1} =
               Presentation.return_target(restored.workspace.agent_ui.view.presentation)

      assert restored.agent_connection.session_follow_ups == %{}
    end

    test "still restores when the user leaves the workspace before the session binds", %{
      state: state,
      dir: dir
    } do
      saved = save_record(dir, "restored while away")
      opened = AgentCommands.open_session(state, saved)
      [%Workspace{id: agent_workspace}] = agent_workspaces(opened)
      provider = assert_provider_held()

      away = opened |> MingaEditor.TabWorkflow.switch(1) |> AgentSessionStart.settle()
      assert TabBar.active_workspace_id(away.shell_runtime.state.tab_bar) == 0

      assert %Workspace{payload: %{session: session}} =
               TabBar.get_workspace(away.shell_runtime.state.tab_bar, agent_workspace)

      assert is_pid(session)

      HeldStartProvider.release(provider)
      settled = settle_through_editor(away)

      assert inspect(Session.messages(session)) =~ "restored while away"
      assert TabBar.active_workspace_id(settled.shell_runtime.state.tab_bar) == 0
    end
  end

  describe "a Restore or reopen into a tab whose provider is still starting" do
    test "Restore does not wait for provider start and shows the conversation once the session answers",
         %{state: state, dir: dir} do
      saved = save_record(dir, "restored into a starting tab")
      bound = state |> AgentCommands.new_agent_session() |> AgentSessionStart.settle()
      provider = assert_provider_held()
      session = Runtime.active_session(bound.shell_runtime)
      assert is_pid(session)

      {elapsed, opened} = :timer.tc(fn -> AgentCommands.open_session(bound, saved) end)
      assert elapsed < @editor_budget_us

      HeldStartProvider.release(provider)
      restored = settle_through_editor(opened)

      assert inspect(Session.messages(session)) =~ "restored into a starting tab"

      # The restored view records the tab the user restored from, for the return trip.
      agent_tab = Runtime.active_tab(bound.shell_runtime).id

      assert %{active_tab_id: ^agent_tab} =
               Presentation.return_target(restored.workspace.agent_ui.view.presentation)
    end

    test "a Sessions picker reopen does not wait for provider start", %{state: state, dir: dir} do
      saved = save_record(dir, "picked while starting")
      bound = state |> AgentCommands.new_agent_session() |> AgentSessionStart.settle()
      provider = assert_provider_held()
      session = Runtime.active_session(bound.shell_runtime)
      owner = TabBar.active_workspace_id(bound.shell_runtime.state.tab_bar)

      choice = %Item{
        id: {saved, {:disk, {owner, session, displayed_session_id(session)}}},
        label: "saved"
      }

      {elapsed, picked} = :timer.tc(fn -> AgentSessionSource.on_select(choice, bound) end)
      assert elapsed < @editor_budget_us

      HeldStartProvider.release(provider)
      reopened = settle_through_editor(picked)

      assert inspect(Session.messages(session)) =~ "picked while starting"
      assert reopened.agent_connection.session_follow_ups == %{}
    end

    test "a Sessions picker reopen of a conversation the tab no longer shows is refused", %{
      state: state,
      dir: dir
    } do
      saved = save_record(dir, "stale choice")
      bound = state |> AgentCommands.new_agent_session() |> AgentSessionStart.settle()
      provider = assert_provider_held()
      session = Runtime.active_session(bound.shell_runtime)
      owner = TabBar.active_workspace_id(bound.shell_runtime.state.tab_bar)

      choice = %Item{
        id: {saved, {:disk, {owner, session, "an-earlier-conversation"}}},
        label: "saved"
      }

      picked = AgentSessionSource.on_select(choice, bound)
      HeldStartProvider.release(provider)
      refused = settle_through_editor(picked)

      assert refused.shell_runtime.state.notice.message == "Session changed. Reopen Sessions."
      refute inspect(Session.messages(session)) =~ "stale choice"
    end
  end

  describe "a Sessions picker choice made from a file" do
    test "opens the chosen conversation in an Agent tab, which takes the keyboard from the tasks drawer",
         %{state: state, dir: dir} do
      saved = save_record(dir, "picked from a file")
      assert Runtime.active_tab_kind(state.shell_runtime) == :file
      state = TasksDrawerWorkflow.open(state)
      assert TasksDrawerWorkflow.focused?(state)

      picker_state =
        %PickerState{
          picker:
            Picker.new([%Item{id: {saved, {:disk, nil}}, label: "saved"}], title: "Sessions"),
          source: AgentSessionSource,
          restore: 0
        }
        |> PickerState.begin_query_session()

      opened = ModalWorkflow.open(state, {:picker, PickerPayload.new(picker_state)})
      generation = picker_state.activation_offer.generation
      picked = GuiActionHandler.dispatch(opened, {:picker_item_activate, generation, 1})
      provider = assert_provider_held()

      bound = AgentSessionStart.settle(picked)
      HeldStartProvider.release(provider)
      shown = settle_through_editor(bound)

      session = Runtime.active_session(shown.shell_runtime)
      assert Runtime.active_tab_kind(shown.shell_runtime) == :agent
      assert inspect(Session.messages(session)) =~ "picked from a file"
      refute TasksDrawerWorkflow.focused?(shown)
    end

    test "resuming twice leaves no empty record in Sessions", %{state: state, dir: dir} do
      first = save_record(dir, "first conversation")
      second = save_record(dir, "second conversation")
      before = SessionStore.list_recoverable(dir)

      shown = resume_from_file(state, first)
      shown = shown |> MingaEditor.TabWorkflow.switch(1) |> resume_from_file(second)
      assert inspect(Session.messages(Runtime.active_session(shown.shell_runtime))) =~ "second"

      after_resumes = SessionStore.list_recoverable(dir)

      refute Enum.any?(after_resumes, &match?({:conversation, %{turn_count: 0}}, &1)),
             "Sessions lists a record with no turns: #{inspect(after_resumes)}"

      assert length(after_resumes) == length(before)
    end
  end

  describe "a remote Agent tab" do
    test "a Sessions picker reopen whose tab shows a session on another node is refused", %{
      state: state,
      dir: dir
    } do
      saved = save_record(dir, "never sent to the remote node")
      {remote_state, remote_workspace, remote} = with_remote_agent_tab(state, :active)
      assert Runtime.active_session(remote_state.shell_runtime) == remote

      choice = %Item{
        id: {saved, {:disk, {remote_workspace, remote, "remote-session"}}},
        label: "saved"
      }

      refused = AgentSessionSource.on_select(choice, remote_state)

      assert refused.shell_runtime.state.notice.message ==
               "Saved sessions open only in a local Agent workspace."

      assert refused.agent_connection.session_follow_ups == %{}
    end

    test "a Restore opens in a local Agent tab, never in the remote one", %{
      state: state,
      dir: dir
    } do
      saved = save_record(dir, "restored beside a remote tab")
      {remote_state, remote_workspace, _remote} = with_remote_agent_tab(state, :inactive)

      opened = AgentCommands.open_session(remote_state, saved)
      provider = assert_provider_held()
      tabs = opened.shell_runtime.state.tab_bar

      assert %Tab{kind: :agent, payload: %{remote_session_id: nil}} = TabBar.active(tabs)
      refute TabBar.active_workspace_id(tabs) == remote_workspace

      bound = AgentSessionStart.settle(opened)
      session = Runtime.active_session(bound.shell_runtime)
      HeldStartProvider.release(provider)
      _restored = settle_through_editor(bound)

      assert inspect(Session.messages(session)) =~ "restored beside a remote tab"
    end
  end

  describe "a follow-up that does not succeed" do
    test "a failed Restore in front is reported in a notice", %{state: state} do
      opened = AgentCommands.open_session(state, "no-such-saved-session")
      provider = assert_provider_held()
      bound = AgentSessionStart.settle(opened)
      session = Runtime.active_session(bound.shell_runtime)

      HeldStartProvider.release(provider)
      failed = settle_through_editor(bound)

      assert failed.shell_runtime.state.notice.message =~ "Could not restore the saved session."
      assert Runtime.active_session(failed.shell_runtime) == session
    end

    test "a failed Restore in the background is shown in that tab's conversation", %{state: state} do
      opened = AgentCommands.open_session(state, "no-such-saved-session")
      [%Workspace{id: agent_workspace}] = agent_workspaces(opened)
      provider = assert_provider_held()
      away = opened |> MingaEditor.TabWorkflow.switch(1) |> AgentSessionStart.settle()

      assert %Workspace{payload: %{session: session}} =
               TabBar.get_workspace(away.shell_runtime.state.tab_bar, agent_workspace)

      HeldStartProvider.release(provider)
      failed = settle_through_editor(away)

      assert Enum.any?(Session.messages(session), fn
               {:system, "Could not restore the saved session." <> _, :error} -> true
               _other -> false
             end)

      assert failed.agent_connection.session_follow_ups == %{}
    end

    test "a session that has not answered by the deadline is reported, and its late answer still restores",
         %{state: state, dir: dir} do
      saved = save_record(dir, "answered late")
      opened = AgentCommands.open_session(state, saved)
      provider = assert_provider_held()
      bound = AgentSessionStart.settle(opened)
      session = Runtime.active_session(bound.shell_runtime)
      [token] = Map.keys(bound.agent_connection.session_follow_ups)

      {:noreply, overdue} =
        MingaEditor.handle_info({:agent_session_follow_up_timeout, token}, bound)

      assert overdue.shell_runtime.state.notice.message =~ "has not loaded after 15 seconds"

      HeldStartProvider.release(provider)
      restored = settle_through_editor(overdue)

      assert inspect(Session.messages(session)) =~ "answered late"
      assert restored.agent_connection.session_follow_ups == %{}

      assert %{active_tab_id: 1} =
               Presentation.return_target(restored.workspace.agent_ui.view.presentation)
    end

    test "a session that exits before answering is reported", %{state: state} do
      opened =
        AgentSession.start_agent_session(state,
          session_start_hook_enabled?: false,
          follow_up: {:seed, [{:user, "lost"}]}
        )

      _provider = assert_provider_held()
      bound = AgentSessionStart.settle(opened)
      assert [%Workspace{payload: %{session: session}}] = agent_workspaces(bound)

      Process.exit(session, :kill)
      assert_receive {:DOWN, _ref, :process, ^session, :killed} = down, 2_000
      {:noreply, reported} = MingaEditor.handle_info(down, bound)

      assert reported.shell_runtime.state.notice.message =~ "stopped before Inline Ask history"
      assert reported.agent_connection.session_follow_ups == %{}
    end
  end

  describe "an Inline Ask seed into a started session" do
    test "does not wait for provider start and seeds once the session answers", %{state: state} do
      messages = [{:user, "What is this?"}, {:assistant, "It authenticates users."}]

      opened =
        AgentSession.start_agent_session(state,
          session_start_hook_enabled?: false,
          follow_up: {:seed, messages}
        )

      provider = assert_provider_held()

      {elapsed, bound} = :timer.tc(fn -> AgentSessionStart.settle(opened) end)
      assert elapsed < @editor_budget_us
      assert [%Workspace{payload: %{session: session}}] = agent_workspaces(bound)
      assert is_pid(session)

      HeldStartProvider.release(provider)
      _seeded = settle_through_editor(bound)

      assert inspect(Session.messages(session)) =~ "It authenticates users."
    end
  end

  # A file tab and a session manager that starts real sessions whose provider
  # start is held, with persistence in the test's own directory.
  @spec state(String.t()) :: MingaEditor.State.t()
  defp state(dir) do
    state = TestHelpers.base_state(rendering: :disabled)

    state =
      MingaEditor.WorkspaceWorkflow.install_tab_bar(state, TabBar.new(Tab.new_file(1, "f.ex")))

    connection = AgentConnection.new(HeldStartProvider, test_pid: self())
    %{state | agent_connection: %{connection | session_manager: held_manager(dir)}}
  end

  # Chooses `saved` in Sessions from the file tab in front, as a click would, and waits until it shows.
  defp resume_from_file(state, saved) do
    picker_state =
      %PickerState{
        picker: Picker.new([%Item{id: {saved, {:disk, nil}}, label: "saved"}], title: "Sessions"),
        source: AgentSessionSource,
        restore: 0
      }
      |> PickerState.begin_query_session()

    opened = ModalWorkflow.open(state, {:picker, PickerPayload.new(picker_state)})
    generation = picker_state.activation_offer.generation

    picked =
      opened
      |> GuiActionHandler.dispatch({:picker_item_activate, generation, 1})
      |> AgentSessionStart.settle()

    # A resume that started a session holds its provider until released; one into an open tab starts none.
    receive do
      {:provider_start_held, provider} -> HeldStartProvider.release(provider)
    after
      2_000 -> :ok
    end

    settle_through_editor(picked)
  end

  # The manager outlives a session the test kills and stops its sessions when the test ends.
  @spec held_manager(String.t()) :: pid()
  defp held_manager(dir) do
    test = self()

    spawn_link(fn ->
      Process.flag(:trap_exit, true)
      serve_starts(test, dir)
    end)
  end

  @spec serve_starts(pid(), String.t()) :: no_return()
  defp serve_starts(test, dir) do
    receive do
      {:"$gen_call", from, {:start_session, opts}} ->
        opts = Keyword.merge(opts, session_store_dir: dir, hooks_enabled?: false)
        {:ok, session} = Session.start_link(opts)
        GenServer.reply(from, {:ok, "follow-up-session", session})
        serve_starts(test, dir)

      {:EXIT, ^test, reason} ->
        exit(reason)

      {:EXIT, _session, _reason} ->
        serve_starts(test, dir)
    end
  end

  @spec assert_provider_held() :: pid()
  defp assert_provider_held do
    assert_receive {:provider_start_held, provider}, 5_000
    provider
  end

  # Delivers the session's replies through the Editor's message handling until no follow-up is outstanding.
  @spec settle_through_editor(MingaEditor.State.t()) :: MingaEditor.State.t()
  defp settle_through_editor(%{agent_connection: %{session_follow_ups: pending}} = state)
       when map_size(pending) == 0,
       do: state

  defp settle_through_editor(state) do
    receive do
      {[:alias | _ref], _reply} = reply ->
        {:noreply, state} = MingaEditor.handle_info(reply, state)
        settle_through_editor(state)
    after
      5_000 -> flunk("expected the session's follow-up reply")
    end
  end

  # The session's first connection event names the conversation it shows, without a call that waits.
  @spec displayed_session_id(pid()) :: String.t()
  defp displayed_session_id(session) do
    assert_receive {:agent_event, ^session,
                    {:connection_changed, %{target: %{session_id: session_id}}}},
                   2_000

    session_id
  end

  # A connected remote Agent workspace whose session pid lives on another node.
  @spec with_remote_agent_tab(MingaEditor.State.t(), :active | :inactive) ::
          {MingaEditor.State.t(), non_neg_integer(), pid()}
  defp with_remote_agent_tab(state, placement) do
    remote = remote_pid()

    workspace =
      Workspace.new_agent(5, "Remote", remote)
      |> Workspace.put_remote_session("build host", "remote-session", :connected)

    tabs = TabBar.restore_workspaces(state.shell_runtime.state.tab_bar, [workspace], nil)
    [%Tab{id: remote_tab}] = TabBar.tabs_in_workspace(tabs, workspace.id)
    tabs = if placement == :active, do: %{tabs | active_id: remote_tab}, else: tabs
    {MingaEditor.WorkspaceWorkflow.install_tab_bar(state, tabs), workspace.id, remote}
  end

  # A pid on a node this test never connects to.
  @spec remote_pid() :: pid()
  defp remote_pid do
    node = "remote@nowhere"
    :erlang.binary_to_term(<<131, 88, 119, byte_size(node), node::binary, 1::32, 0::32, 1::32>>)
  end

  @spec agent_workspaces(MingaEditor.State.t()) :: [Workspace.t()]
  defp agent_workspaces(state),
    do: Enum.filter(state.shell_runtime.state.tab_bar.workspaces, &(&1.kind == :agent))

  @spec save_record(String.t(), String.t()) :: String.t()
  defp save_record(dir, question) do
    id = "saved-#{System.unique_integer([:positive])}"

    :ok =
      SessionStore.save(
        %{
          id: id,
          timestamp: DateTime.to_iso8601(DateTime.utc_now()),
          model_name: "test-model",
          messages: [{:user, question}, {:assistant, "reply"}],
          continuation: MingaAgent.Session.Continuation.new(),
          usage: %MingaAgent.TurnUsage{
            input: 1,
            output: 1,
            cache_read: 0,
            cache_write: 0,
            cost: 0.0
          }
        },
        dir
      )

    id
  end
end
