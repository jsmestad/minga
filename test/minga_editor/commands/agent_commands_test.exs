defmodule MingaEditor.Commands.AgentCommandsTest do
  @moduledoc """
  Characterization tests for Commands.Agent.

  Tests pure `state -> state` functions for agent-related commands.
  Agent state now lives on EditorState (agent panel, session, status).

  Functions that require a live Agent.Session (submit_prompt, abort_agent,
  clear_chat_display, etc.) are tested via EditorCase integration tests
  in a separate file.
  """

  use ExUnit.Case, async: false

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Session
  alias MingaAgent.Session.{ConnectionSnapshot, ConnectionTarget}
  alias MingaAgent.Test.ModelSelectionFixture
  alias Minga.Editing.Scroll
  alias MingaEditor.Agent.CatalogStartup
  alias MingaEditor.Agent.DraftWorkflow
  alias MingaEditor.Agent.DraftSave
  alias Minga.Test.AgentSessionStart
  alias MingaEditor.Agent.Ingest
  alias Minga.Test.TranscriptFixture
  alias MingaEditor.Agent.StartFailure
  alias MingaEditor.Agent.StartRequest
  alias MingaEditor.Agent.TurnRequest
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.UIState.View
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Project.FileRef
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.PickerUI
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.Workflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentConnection
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Frontend
  alias MingaEditor.State.Interaction
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Agent, as: TabAgent
  alias MingaEditor.State.Workspace.Agent, as: WorkspaceAgent
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Session.State, as: WorkspaceState
  alias MingaEditor.UI.Picker.AgentHistorySource
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias Minga.Test.SessionSlowMockProvider
  alias Minga.Test.StubServer

  setup_all do
    _providers = LLMDB.providers()
    :ok
  end

  defmodule RestartStubSession do
    use GenServer

    @spec start_link(pid()) :: GenServer.on_start()
    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl GenServer
    def init(test_pid), do: {:ok, test_pid}

    @impl GenServer
    def handle_call(:restart_provider, _from, test_pid) do
      send(test_pid, :restart_provider_called)
      {:reply, :ok, test_pid}
    end
  end

  defmodule RejectingModelSession do
    use GenServer

    @spec start_link(String.t()) :: GenServer.on_start()
    def start_link(message), do: GenServer.start_link(__MODULE__, message)

    @impl GenServer
    def init(message), do: {:ok, message}

    @impl GenServer
    def handle_call({:set_model_for_target, %{session: session}, "missing"}, _from, message)
        when session == self(),
        do: {:reply, {:error, message}, message}
  end

  defmodule RestorableModelSession do
    use GenServer

    @spec start_link(MingaAgent.ModelSelection.t()) :: GenServer.on_start()
    def start_link(selection), do: GenServer.start_link(__MODULE__, selection)

    @impl GenServer
    def init(selection), do: {:ok, selection}

    @impl GenServer
    def handle_call({:load_session, _session_id, nil}, _from, selection),
      do: {:reply, :ok, selection}

    def handle_call(:model_selection, _from, selection),
      do: {:reply, selection, selection}
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp command!(name) do
    Enum.find(AgentCommands.__commands__(), &(&1.name == name)) || raise "missing command #{name}"
  end

  defp base_state(opts \\ []) do
    {:ok, buf} = BufferProcess.start_link(content: Keyword.get(opts, :content, "hello\nworld"))

    {:ok, prompt_buf} = BufferProcess.start_link(content: "")

    default_session =
      if Keyword.has_key?(opts, :session) do
        Keyword.get(opts, :session)
      else
        {:ok, pid} = StubServer.start_link()
        pid
      end

    agent = %AgentState{}

    agentic = %UIState{
      panel: %UIState.Panel{
        visible: Keyword.get(opts, :panel_visible, true),
        input_focused: Keyword.get(opts, :input_focused, false),
        prompt_buffer: prompt_buf
      }
    }

    agent_tab = Tab.new_agent(1, "Agent")
    {tb, workspace} = agent_tab |> TabBar.new() |> TabBar.add_workspace("Agent", default_session)

    tb =
      tb
      |> TabBar.move_tab_to_workspace(agent_tab.id, workspace.id)
      |> TabBar.set_workspace_agent_ui(workspace.id, agentic)

    %EditorState{
      frontend: %Frontend{port_manager: nil},
      workspace: %MingaEditor.Session.State{
        editing: VimState.new(),
        buffers: %Buffers{active: buf, list: [buf], active_index: 0},
        windows: %Windows{
          tree: {:leaf, 1},
          map: %{1 => Window.new(1, buf, 24, 80)},
          active: 1,
          next_id: 2
        },
        agent_ui: agentic
      },
      # Keys in these tests go through the input handlers, which ask the sidebar table who has focus.
      # The table is this state's own, so a sidebar another test opened cannot take them (#4271).
      extension_surfaces:
        MingaEditor.State.ExtensionSurfaces.new(sidebar_registry: private_sidebar_registry()),
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Traditional.State.replace_agent(
              %MingaEditor.Shell.Traditional.State{},
              agent
            ),
            tb
          )
        ),
      interaction: %Interaction{}
    }
  end

  defp private_sidebar_registry do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({MingaEditor.Extension.Sidebar, name: table, notify: false}, id: table)
    table
  end

  @spec stop_owned_prompt(pid()) :: :ok
  defp stop_owned_prompt(pid) when is_pid(pid) do
    GenServer.stop(pid)
  catch
    :exit, {:noproc, {GenServer, :stop, [^pid, :normal, :infinity]}} -> :ok
  end

  defp with_model_name(state, model_name) do
    agent_ui = UIState.set_model_name(state.workspace.agent_ui, model_name)
    MingaEditor.Shell.Traditional.Workflow.install_agent_ui(state, agent_ui)
  end

  defp install_tab_bar(state, tab_bar) do
    shell_state =
      MingaEditor.Shell.Traditional.State.install_tab_bar(state.shell_runtime.state, tab_bar)

    %{state | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)}
  end

  defp source_workspace_state do
    state = base_state(session: nil)
    source_ref = FileRef.from_buffer(state.workspace.buffers.active)

    file_tab =
      Tab.new_file(1, FileRef.display_label(source_ref))
      |> Tab.set_file_ref(source_ref)
      |> Tab.set_context(WorkspaceState.to_tab_context(state.workspace))

    tab_bar =
      file_tab
      |> TabBar.new()
      |> TabBar.add_workspace_file(0, source_ref)

    install_tab_bar(state, tab_bar)
  end

  defp source_workspace_with_background_agent_tab do
    state = source_workspace_state()
    {tab_bar, _agent_tab} = TabBar.insert(state.shell_runtime.state.tab_bar, :agent, "Agent")

    install_tab_bar(state, tab_bar)
  end

  defp active_agent_workspace_state do
    state = base_state()
    windows = agent_windows()

    workspace =
      state.workspace
      |> MingaEditor.Session.State.set_buffers(%Buffers{
        active: nil,
        list: [],
        active_index: 0
      })
      |> MingaEditor.Session.State.set_windows(windows)
      |> MingaEditor.Session.State.set_agent_ui(UIState.new())

    %{state | workspace: workspace}
  end

  defp agent_windows do
    win_id = 1

    %Windows{
      tree: WindowTree.new(win_id),
      map: %{win_id => Window.new_agent_chat(win_id, 24, 80)},
      active: win_id,
      next_id: win_id + 1
    }
  end

  defmodule PromptRejectingProvider do
    @behaviour MingaAgent.Provider

    use GenServer

    @impl MingaAgent.Provider
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl MingaAgent.Provider
    def send_prompt(pid, _text), do: GenServer.call(pid, :send_prompt)

    @impl MingaAgent.Provider
    def abort(pid, _request_id), do: GenServer.cast(pid, :abort)

    @impl MingaAgent.Provider
    def new_session(pid), do: GenServer.cast(pid, :new_session)

    @impl MingaAgent.Provider
    def get_state(_pid) do
      {:ok,
       %{
         model: %{id: "test-model", name: "Test Model", provider: "test"},
         is_streaming: false,
         token_usage: nil
       }}
    end

    @impl GenServer
    def init(opts) do
      {:ok, %{send_prompt_result: Keyword.fetch!(opts, :send_prompt_result)}}
    end

    @impl GenServer
    def handle_call(:send_prompt, _from, state), do: {:reply, state.send_prompt_result, state}

    @impl GenServer
    def handle_cast(:abort, state), do: {:noreply, state}

    @impl GenServer
    def handle_cast(:new_session, state), do: {:noreply, state}
  end

  defmodule ReadinessSession do
    use GenServer

    @spec start_link(pid()) :: GenServer.on_start()
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl GenServer
    def init(owner), do: {:ok, owner}

    @impl GenServer
    def handle_call(:model_selection, _from, state) do
      {:reply, MingaAgent.Test.ModelSelectionFixture.selection(), state}
    end

    def handle_call({:send_prompt, content}, _from, owner) do
      send(owner, {:readiness_session_prompt, content})
      {:reply, :ok, owner}
    end
  end

  defp project_prompt_connection(state, owner, readiness, phase, error \\ nil) do
    selection = ModelSelectionFixture.selection()

    connection = %ConnectionSnapshot{
      target: ConnectionTarget.new(owner, "prompt-readiness-test", selection, make_ref()),
      credential_readiness: readiness,
      model_selection: selection,
      provider_phase: phase,
      operation: :idle,
      problem: if(error, do: {:provider, :startup_failed})
    }

    ui = UIState.project_connection(state.workspace.agent_ui, connection)

    Workflow.install_agent_ui(state, ui)
  end

  # ── submit_prompt ────────────────────────────────────────────────────────

  describe "submit_prompt/1" do
    test "no-ops on empty input" do
      state = base_state()
      assert AgentCommands.submit_prompt(state) == state
    end

    test "sensitive slash commands do not enter history" do
      state =
        base_state()
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
            state,
            (&MingaEditor.Agent.PromptBuffer.set_prompt_text(&1, "/login --COMPLETE ref code")).(
              state.workspace.agent_ui
            )
          )
        end)

      new_state = state |> AgentCommands.submit_prompt() |> Minga.Test.TurnRequestDriver.settle()

      assert new_state.workspace.agent_ui.panel.prompt_history == []
      assert MingaEditor.Agent.PromptBuffer.prompt_text(new_state.workspace.agent_ui.panel) == ""
    end

    test "a rejected provider argument does not leak into history or the transcript" do
      {:ok, session} = StubServer.start_link(notify: self())

      state =
        base_state(session: session) |> AgentCommands.input_paste("/auth\trevoke secret-value")

      new_state = state |> AgentCommands.submit_prompt() |> Minga.Test.TurnRequestDriver.settle()

      assert new_state.workspace.agent_ui.panel.prompt_history == []
      assert MingaEditor.Agent.PromptBuffer.prompt_text(new_state.workspace.agent_ui.panel) == ""
      assert_receive {:stub_system_message, message, _level}
      assert message =~ "Choose a supported provider to revoke:"
      refute message =~ "secret-value"
    end

    test "indented credential commands are cleared without entering history or reaching the session" do
      session = start_supervised!({StubServer, notify: self()})
      state = base_state(session: session)

      for {submit, status, text} <- [
            {&AgentCommands.submit_prompt/1, :idle, "  /auth openai credential-sentinel"},
            {&AgentCommands.scope_queue_follow_up/1, :thinking,
             "  /LOGIN --complete ref callback-sentinel"}
          ] do
        agent = MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)

        result =
          state
          |> Workflow.install_agent_state(AgentState.set_status(agent, status))
          |> AgentCommands.input_paste(text)
          |> submit.()

        assert result.workspace.agent_ui.panel.prompt_history == []
        assert MingaEditor.Agent.PromptBuffer.prompt_text(result.workspace.agent_ui.panel) == ""

        assert result.shell_runtime.state.notice.message ==
                 "Credential commands must start at the beginning of the prompt."

        :sys.get_state(session)
        refute_received {:stub_system_message, _, _}
      end
    end

    test "unknown slash command preserves draft and reports the error in chat" do
      {:ok, session} = StubServer.start_link(notify: self())

      state =
        base_state(session: session)
        |> AgentCommands.input_paste("/modle")

      new_state = state |> AgentCommands.submit_prompt() |> Minga.Test.TurnRequestDriver.settle()

      assert MingaEditor.Agent.PromptBuffer.prompt_text(new_state.workspace.agent_ui.panel) ==
               "/modle"

      assert new_state.shell_runtime.state.notice.message ==
               "Unknown command: /modle. Did you mean /model?"

      assert_receive {:stub_system_message, "Unknown command: /modle. Did you mean /model?",
                      :error}
    end

    test "blocks submit and preserves draft when no model is configured" do
      state =
        base_state(session: nil)
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
            state,
            (fn ui ->
               ui = MingaEditor.Agent.PromptBuffer.ensure(ui)
               BufferProcess.replace_content(ui.panel.prompt_buffer, "hello agent")
               ui
             end).(state.workspace.agent_ui)
          )
        end)
        |> replace_panel(fn panel ->
          panel
          |> Panel.set_credentials_configured(false)
          |> Panel.set_model_name(AgentConfig.unconfigured_model())
          |> Panel.set_provider_name("")
        end)

      new_state = state |> AgentCommands.submit_prompt() |> Minga.Test.TurnRequestDriver.settle()

      assert new_state.shell_runtime.state.notice.message =~ "No model configured"

      assert MingaEditor.Agent.PromptBuffer.prompt_text(new_state.workspace.agent_ui.panel) ==
               "hello agent"
    end

    test "sets error status when model is configured but no session exists" do
      state = base_state(session: nil)

      state =
        state
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
            state,
            (fn ui ->
               ui = MingaEditor.Agent.PromptBuffer.ensure(ui)
               BufferProcess.replace_content(ui.panel.prompt_buffer, "hello agent")
               ui
             end).(state.workspace.agent_ui)
          )
        end)
        |> replace_panel(fn panel ->
          panel
          |> Panel.set_credentials_configured(true)
          |> Panel.set_model_name("openai:gpt-5")
          |> Panel.set_provider_name("openai")
        end)

      new_state = state |> AgentCommands.submit_prompt() |> Minga.Test.TurnRequestDriver.settle()

      assert new_state.shell_runtime.state.notice.message =~ "No agent session"

      assert MingaEditor.Agent.PromptBuffer.prompt_text(new_state.workspace.agent_ui.panel) ==
               "hello agent"
    end

    test "uses the active Session projection for blocked prompts and keeps their draft" do
      session = start_supervised!({ReadinessSession, self()})

      for {readiness, phase, error, expected} <- [
            {:unconfigured, :stopped, nil,
             "No provider credentials are configured for this model"},
            {:checking, :stopped, nil, "Checking hosted provider credentials"},
            {:configured, :starting, nil, "Agent provider still starting"}
          ] do
        state =
          base_state(session: session)
          |> project_prompt_connection(session, readiness, phase, error)
          |> AgentCommands.input_paste("draft prompt")
          |> AgentCommands.submit_prompt()

        assert state.shell_runtime.state.notice.message =~ expected

        assert MingaEditor.Agent.PromptBuffer.prompt_text(state.workspace.agent_ui.panel) ==
                 "draft prompt"
      end

      refute_received {:readiness_session_prompt, _prompt}
    end

    test "Enter after a provider start failure retries the provider and keeps the draft unsent" do
      session = start_supervised!({ReadinessSession, self()})
      tasks = start_supervised!(Task.Supervisor)
      scheduler = start_supervised!({EffectScheduler, task_supervisor: tasks})
      :ok = EffectScheduler.attach(scheduler, self())

      state =
        %{base_state(session: session) | effect_scheduler: scheduler}
        |> project_prompt_connection(session, :configured, :terminal_failure, "boom")
        |> AgentCommands.input_paste("draft prompt")
        |> AgentCommands.submit_prompt()

      assert_receive {:effect_result, ^scheduler,
                      %Outcome{
                        request: %{effect: %MingaEditor.Agent.ConnectionAction{intent: :retry}}
                      }},
                     2_000

      assert MingaEditor.Agent.PromptBuffer.prompt_text(state.workspace.agent_ui.panel) ==
               "draft prompt"

      refute_received {:readiness_session_prompt, _prompt}
    end

    test "Enter during a setup failure runs a known slash command, and plain text opens setup" do
      session = start_supervised!({ReadinessSession, self()})

      failed =
        base_state(session: session)
        |> project_prompt_connection(session, :unconfigured, :terminal_failure, "boom")

      assert UIState.start_remedy(failed.workspace.agent_ui) == :set_up_provider

      ran = failed |> AgentCommands.input_paste("/help") |> AgentCommands.submit_prompt()

      assert MingaEditor.Agent.PromptBuffer.prompt_text(ran.workspace.agent_ui.panel) == ""
      refute match?({:picker, _}, ran.shell_runtime.state.modal)

      remedied = failed |> AgentCommands.input_paste("hello") |> AgentCommands.submit_prompt()

      assert {:picker, %{picker_ui: %{source: MingaEditor.UI.Picker.AgentModelSource}}} =
               remedied.shell_runtime.state.modal

      assert MingaEditor.Agent.PromptBuffer.prompt_text(remedied.workspace.agent_ui.panel) ==
               "hello"

      refute_received {:readiness_session_prompt, _prompt}
    end

    test "Enter in a live conversation still submits the draft" do
      session = start_supervised!({ReadinessSession, self()})

      base_state(session: session)
      |> project_prompt_connection(session, :configured, :running)
      |> AgentCommands.input_paste("send me")
      |> AgentCommands.submit_prompt()

      assert_receive {:readiness_session_prompt, _prompt}, 2_000
    end

    test "keeps a draft and reports the published provider error while the route retries" do
      session = start_supervised!({ReadinessSession, self()})

      state =
        base_state(session: session)
        |> project_prompt_connection(session, :configured, :retrying)
        |> Workflow.install_agent_error("Provider disconnected")
        |> AgentCommands.input_paste("draft during retry")
        |> AgentCommands.submit_prompt()

      assert state.shell_runtime.state.notice.message ==
               "Failed to start agent: Provider disconnected. Your prompt was preserved."

      assert MingaEditor.Agent.PromptBuffer.prompt_text(state.workspace.agent_ui.panel) ==
               "draft during retry"

      refute_received {:readiness_session_prompt, _prompt}
    end

    test "blocks a ready projection owned by another Session or superseded by unavailability" do
      session = start_supervised!({ReadinessSession, self()})

      for {owner, lifecycle, expected} <- [
            {self(), {:conversation, self()}, "Agent provider still starting"},
            {session, :unavailable, "Agent session unavailable"}
          ] do
        state =
          base_state(session: session)
          |> project_prompt_connection(owner, :configured, :running)
          |> AgentCommands.input_paste("keep me")

        ui = UIState.transition_chat(state.workspace.agent_ui, lifecycle)
        state = state |> Workflow.install_agent_ui(ui) |> AgentCommands.submit_prompt()

        assert state.shell_runtime.state.notice.message =~ expected

        assert MingaEditor.Agent.PromptBuffer.prompt_text(state.workspace.agent_ui.panel) ==
                 "keep me"
      end

      refute_received {:readiness_session_prompt, _prompt}
    end

    test "ready provider clears the prompt without discarding earlier Changes" do
      session = start_supervised!({ReadinessSession, self()})

      state =
        base_state(session: session)
        |> project_prompt_connection(session, :configured, :running)
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
            state,
            (fn ui ->
               ui = MingaEditor.Agent.PromptBuffer.ensure(ui)
               BufferProcess.replace_content(ui.panel.prompt_buffer, "ready prompt")
               ui
             end).(state.workspace.agent_ui)
            |> MingaEditor.Agent.UIState.replace_edit_timeline(
              MingaEditor.Agent.EditTimeline.recover_files(
                MingaEditor.Agent.EditTimeline.new(),
                %{"first-turn.ex" => 1}
              )
            )
          )
        end)
        |> replace_panel(fn panel ->
          panel
          |> Panel.set_credentials_configured(true)
          |> Panel.set_model_name("anthropic:claude-sonnet-4-20250514")
          |> Panel.set_provider_name("anthropic")
        end)

      new_state = state |> AgentCommands.submit_prompt() |> Minga.Test.TurnRequestDriver.settle()

      assert_receive {:readiness_session_prompt, "ready prompt"}
      assert MingaEditor.Agent.PromptBuffer.prompt_text(new_state.workspace.agent_ui.panel) == ""

      assert [%{path: "first-turn.ex"}] =
               MingaEditor.Agent.EditTimeline.file_summaries(
                 new_state.workspace.agent_ui.view.edit_timeline
               )
    end

    test "unresolved file mention preserves the prompt and does not send" do
      session = start_supervised!({ReadinessSession, self()})

      state =
        base_state(session: session)
        |> project_prompt_connection(session, :configured, :running)
        |> AgentCommands.input_paste("@missing.ex explain")
        |> replace_panel(fn panel ->
          panel
          |> Panel.set_credentials_configured(true)
          |> Panel.set_model_name("anthropic:claude-sonnet-4-20250514")
          |> Panel.set_provider_name("anthropic")
        end)

      # Mentioned files are read off the Editor; the answer comes back as a message.
      pressed = AgentCommands.submit_prompt(state)
      assert_receive {:composer_mentions_read, read_press, result}
      new_state = AgentCommands.deliver_read_mentions(pressed, read_press, result)

      assert new_state.shell_runtime.state.notice.message =~ "Cannot resolve file mentions"

      assert MingaEditor.Agent.PromptBuffer.prompt_text(new_state.workspace.agent_ui.panel) ==
               "@missing.ex explain"

      refute_received {:readiness_session_prompt, _prompt}
    end

    test "a message whose files were read goes only if its composer still holds exactly the pressed text" do
      session = start_supervised!({ReadinessSession, self()})

      state =
        base_state(session: session)
        |> project_prompt_connection(session, :configured, :running)
        |> AgentCommands.input_paste("@missing.ex explain")
        |> replace_panel(fn panel ->
          panel
          |> Panel.set_credentials_configured(true)
          |> Panel.set_model_name("anthropic:claude-sonnet-4-20250514")
          |> Panel.set_provider_name("anthropic")
        end)

      pressed = AgentCommands.submit_prompt(state)
      assert_receive {:composer_mentions_read, read_press, _result}

      # Typing after the press changes the composer, so the read answer sends nothing.
      edited = AgentCommands.input_paste(pressed, " more")
      kept = AgentCommands.deliver_read_mentions(edited, read_press, {:ok, "resolved"})

      assert kept.shell_runtime.state.notice.message =~ "Not sent"

      assert MingaEditor.Agent.PromptBuffer.prompt_text(kept.workspace.agent_ui.panel) ==
               "@missing.ex explain more"

      refute_received {:readiness_session_prompt, _prompt}
    end

    test "ready local provider sends even when panel credentials cache is stale" do
      session = start_supervised!({ReadinessSession, self()})

      state =
        base_state(session: session)
        |> project_prompt_connection(session, :configured, :running)
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
            state,
            (fn ui ->
               ui = MingaEditor.Agent.PromptBuffer.ensure(ui)
               BufferProcess.replace_content(ui.panel.prompt_buffer, "stale panel prompt")
               ui
             end).(state.workspace.agent_ui)
          )
        end)
        |> replace_panel(fn panel ->
          panel
          |> Panel.set_credentials_configured(false)
          |> Panel.set_model_name("anthropic:claude-sonnet-4-20250514")
          |> Panel.set_provider_name("anthropic")
        end)

      new_state = state |> AgentCommands.submit_prompt() |> Minga.Test.TurnRequestDriver.settle()

      assert_receive {:readiness_session_prompt, "stale panel prompt"}
      assert is_nil(new_state.shell_runtime.state.notice.message)
      assert MingaEditor.Agent.PromptBuffer.prompt_text(new_state.workspace.agent_ui.panel) == ""
    end

    test "preserves the prompt when an attached session rejects locally" do
      for {error, expected_message} <- [
            {:provider_not_ready, "Agent provider still starting"},
            {:credentials_not_configured, "No provider credentials are configured"},
            {:credentials_pending, "Checking hosted provider credentials"}
          ] do
        {:ok, session} =
          Session.start_link(
            provider: PromptRejectingProvider,
            provider_opts: [send_prompt_result: {:error, error}, model: "anthropic:test"],
            persist?: false
          )

        on_exit(fn -> Process.exit(session, :kill) end)
        %{connection: connection} = Session.editor_snapshot(session)

        state =
          base_state(session: session)
          |> then(fn state ->
            ui = UIState.project_connection(state.workspace.agent_ui, connection)
            Workflow.install_agent_ui(state, ui)
          end)
          |> replace_panel(fn panel ->
            panel
            |> Panel.set_credentials_configured(true)
            |> Panel.set_model_name("anthropic:test")
            |> Panel.set_provider_name("test")
          end)
          |> then(fn state ->
            MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
              state,
              (fn ui ->
                 ui = MingaEditor.Agent.PromptBuffer.ensure(ui)
                 BufferProcess.replace_content(ui.panel.prompt_buffer, "draft prompt")
                 ui
               end).(state.workspace.agent_ui)
            )
          end)

        new_state =
          state |> AgentCommands.submit_prompt() |> Minga.Test.TurnRequestDriver.settle()

        assert new_state.shell_runtime.state.notice.message =~ expected_message

        assert MingaEditor.Agent.PromptBuffer.prompt_text(new_state.workspace.agent_ui.panel) ==
                 "draft prompt"
      end
    end
  end

  describe "a send never waits on the Session (#4296)" do
    setup do
      {:ok, session} = GenServer.start(ReadinessSession, self())
      on_exit(fn -> Process.exit(session, :kill) end)

      state =
        base_state(session: session)
        |> project_prompt_connection(session, :configured, :running)
        |> replace_panel(fn panel ->
          panel
          |> Panel.set_credentials_configured(true)
          |> Panel.set_model_name("anthropic:claude-sonnet-4-20250514")
          |> Panel.set_provider_name("anthropic")
        end)

      BufferProcess.replace_content(state.workspace.agent_ui.panel.prompt_buffer, "hello")
      %{session: session, state: state}
    end

    defp composer(state),
      do: MingaEditor.Agent.PromptBuffer.prompt_text(state.workspace.agent_ui.panel)

    defp notice(state), do: state.shell_runtime.state.notice.message

    test "a press returns while the Session is busy, and its answer clears the composer", %{
      session: session,
      state: state
    } do
      :ok = :sys.suspend(session)
      pressed = AgentCommands.submit_prompt(state)

      # A press that had called the busy Session would have timed out and reported it.
      assert [%TurnRequest{session: ^session, work: {:send, :prompt, "hello", "hello"}}] =
               Map.values(pressed.agent_connection.turn_requests)

      assert composer(pressed) == "hello"
      assert notice(pressed) == nil
      refute_received {:readiness_session_prompt, _prompt}

      :ok = :sys.resume(session)
      sent = Minga.Test.TurnRequestDriver.settle(pressed)

      assert_received {:readiness_session_prompt, "hello"}
      assert composer(sent) == ""
      assert sent.agent_connection.turn_requests == %{}
    end

    test "a second press while the send is out does not send the text again", %{
      session: session,
      state: state
    } do
      :ok = :sys.suspend(session)
      pressed = state |> AgentCommands.submit_prompt() |> AgentCommands.submit_prompt()

      assert map_size(pressed.agent_connection.turn_requests) == 1
      assert notice(pressed) =~ "Wait for the earlier message to be sent"

      :ok = :sys.resume(session)
      sent = Minga.Test.TurnRequestDriver.settle(pressed)

      assert_received {:readiness_session_prompt, "hello"}
      refute_received {:readiness_session_prompt, _again}
      assert composer(sent) == ""
    end

    test "text typed after the press stays when the send is answered", %{
      session: session,
      state: state
    } do
      :ok = :sys.suspend(session)
      pressed = AgentCommands.submit_prompt(state)

      BufferProcess.replace_content(
        pressed.workspace.agent_ui.panel.prompt_buffer,
        "hello and a second thought"
      )

      :ok = :sys.resume(session)
      sent = Minga.Test.TurnRequestDriver.settle(pressed)

      assert_received {:readiness_session_prompt, "hello"}
      assert composer(sent) == " and a second thought"
    end

    test "pressed text the user edited meanwhile stays whole, and one line says the message went",
         %{session: session, state: state} do
      :ok = :sys.suspend(session)
      pressed = AgentCommands.submit_prompt(state)
      BufferProcess.replace_content(pressed.workspace.agent_ui.panel.prompt_buffer, "help")

      :ok = :sys.resume(session)
      sent = Minga.Test.TurnRequestDriver.settle(pressed)

      assert composer(sent) == "help"
      assert notice(sent) =~ "The message was sent. Newer edits were kept."
    end

    test "a Session that exits before it answers keeps the text and says why", %{
      session: session,
      state: state
    } do
      :ok = :sys.suspend(session)
      pressed = AgentCommands.submit_prompt(state)
      Process.exit(session, :kill)

      failed = Minga.Test.TurnRequestDriver.settle(pressed)

      assert composer(failed) == "hello"
      assert notice(failed) =~ "Agent session unavailable. Your prompt was preserved."
      assert failed.agent_connection.turn_requests == %{}
    end
  end

  describe "a send takes only the text its press took (#4296)" do
    setup do
      {:ok, session} = GenServer.start(ReadinessSession, self())
      on_exit(fn -> Process.exit(session, :kill) end)

      state =
        base_state(session: session)
        |> project_prompt_connection(session, :configured, :running)
        |> replace_panel(fn panel ->
          panel
          |> Panel.set_credentials_configured(true)
          |> Panel.set_model_name("anthropic:claude-sonnet-4-20250514")
          |> Panel.set_provider_name("anthropic")
        end)

      # A composer with a loaded saved draft, which is what keeps presses in line.
      buffer = state.workspace.agent_ui.panel.prompt_buffer
      marker = BufferProcess.inspection_marker(buffer)

      save =
        {session, "prompt-readiness-test"}
        |> DraftSave.loading(buffer, make_ref(), marker)
        |> DraftSave.loaded(1, marker, nil)

      state =
        Workflow.install_agent_ui(
          state,
          UIState.project_draft_save(state.workspace.agent_ui, save)
        )

      %{state: state, owner: DraftWorkflow.front_owner(state), buffer: buffer}
    end

    defp held_send(buffer, raw),
      do: {:steering, raw, {raw, raw, BufferProcess.inspection_marker(buffer)}}

    test "a held send goes when text follows it, and that text stays", %{
      state: state,
      owner: owner,
      buffer: buffer
    } do
      BufferProcess.replace_content(buffer, "first and typed after")

      sent =
        state
        |> AgentCommands.deliver_held_send(owner, held_send(buffer, "first"))
        |> Minga.Test.TurnRequestDriver.settle()

      assert_received {:readiness_session_prompt, "first"}
      assert composer(sent) == " and typed after"
      assert notice(sent) == nil
    end

    test "two held presses of the same text each send it once", %{
      state: state,
      owner: owner,
      buffer: buffer
    } do
      BufferProcess.replace_content(buffer, "okok")

      once =
        state
        |> AgentCommands.deliver_held_send(owner, held_send(buffer, "ok"))
        |> Minga.Test.TurnRequestDriver.settle()

      assert composer(once) == "ok"

      twice =
        once
        |> AgentCommands.deliver_held_send(owner, held_send(buffer, "ok"))
        |> Minga.Test.TurnRequestDriver.settle()

      assert composer(twice) == ""
      assert_received {:readiness_session_prompt, "ok"}
      assert_received {:readiness_session_prompt, "ok"}
      refute_received {:readiness_session_prompt, _third}
    end

    test "a held send whose text was edited is not sent and keeps the composer", %{
      state: state,
      owner: owner,
      buffer: buffer
    } do
      BufferProcess.replace_content(buffer, "fist")
      kept = AgentCommands.deliver_held_send(state, owner, held_send(buffer, "first"))

      assert kept.agent_connection.turn_requests == %{}
      assert composer(kept) == "fist"
      assert notice(kept) =~ "the message changed after you pressed send"
      refute_received {:readiness_session_prompt, _prompt}
    end

    test "a send with attachments leaves text typed after it unsaved, so the next save writes it",
         %{state: state, owner: owner, buffer: buffer} do
      for {typed_after, saved?} <- [{"", true}, {" and more", false}] do
        BufferProcess.replace_content(buffer, "hello")
        ref = make_ref()
        assert {:ok, "hello", sending} = DraftWorkflow.begin_send(state, ref, :all)
        BufferProcess.replace_content(buffer, "hello" <> typed_after)

        answered = DraftWorkflow.send_answered(sending, owner, ref, "hello", {:sent_attached, 2})

        assert composer(answered) == typed_after

        assert %DraftSave{request: {:ready, 2, saved_marker}, sending: nil} =
                 answered.workspace.agent_ui.draft_save

        assert is_tuple(saved_marker) == saved?
      end
    end
  end

  describe "a stop never waits on the Session (#4296)" do
    defmodule StoppableSession do
      use GenServer

      @spec start(term()) :: GenServer.on_start()
      def start(answer), do: GenServer.start(__MODULE__, answer)

      @impl GenServer
      def init(answer), do: {:ok, answer}

      @impl GenServer
      def handle_call({:stop_turn, _target}, _from, answer), do: {:reply, answer, answer}
    end

    defp stoppable(answer) do
      {:ok, session} = StoppableSession.start(answer)
      on_exit(fn -> Process.exit(session, :kill) end)
      target = {"record", "request"}

      state = base_state(session: session)
      shell = state.shell_runtime.state

      agent =
        shell
        |> MingaEditor.Shell.Traditional.State.agent()
        |> AgentState.project_stop_target(session, target)

      shell = MingaEditor.Shell.Traditional.State.replace_agent(shell, agent)

      {session,
       %{state | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell)}}
    end

    test "a stop returns while the Session is busy and is quiet once the Session stops the turn" do
      {session, state} = stoppable(:ok)
      :ok = :sys.suspend(session)
      asked = AgentCommands.abort_agent(state)

      assert [%TurnRequest{session: ^session, work: {:stop, {"record", "request"}}}] =
               Map.values(asked.agent_connection.turn_requests)

      :ok = :sys.resume(session)
      stopped = Minga.Test.TurnRequestDriver.settle(asked)
      assert stopped.shell_runtime.state.notice.message == nil
      assert stopped.agent_connection.turn_requests == %{}
    end

    test "a stop for a turn that already ended says so" do
      {_session, state} = stoppable({:error, :stale_turn})
      stopped = state |> AgentCommands.abort_agent() |> Minga.Test.TurnRequestDriver.settle()
      assert stopped.shell_runtime.state.notice.message =~ "That Agent turn is no longer active."
    end

    test "a Session that exits before it answers a stop says the stop was not confirmed" do
      {session, state} = stoppable(:ok)
      :ok = :sys.suspend(session)
      asked = AgentCommands.abort_agent(state)
      Process.exit(session, :kill)

      stopped = Minga.Test.TurnRequestDriver.settle(asked)

      assert stopped.shell_runtime.state.notice.message =~
               "Could not confirm the Agent stop request."
    end
  end

  describe "scope_queue_follow_up/1" do
    test "sensitive slash commands do not enter history when queued as follow-up" do
      state = base_state()

      state =
        state
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_state(
            state,
            (&AgentState.set_status(&1, :thinking)).(
              MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)
            )
          )
        end)
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
            state,
            (&MingaEditor.Agent.PromptBuffer.set_prompt_text(
               &1,
               "/login openai --complete ref code"
             )).(state.workspace.agent_ui)
          )
        end)

      new_state = AgentCommands.scope_queue_follow_up(state)

      assert new_state.workspace.agent_ui.panel.prompt_history == []
      assert MingaEditor.Agent.PromptBuffer.prompt_text(new_state.workspace.agent_ui.panel) == ""
    end
  end

  # ── scroll_chat ──────────────────────────────────────────────────────────

  describe "scroll_chat_up/1 and scroll_chat_down/1" do
    test "scrolls when panel is visible" do
      state = base_state(panel_visible: true)
      new_state = AgentCommands.scroll_chat_up(state)

      # Scroll offset should change (exact value depends on panel height)
      assert new_state.workspace.agent_ui.panel.scroll != state.workspace.agent_ui.panel.scroll
    end
  end

  # ── pin message ─────────────────────────────────────────────────────────

  describe "scope_pin_message/1" do
    test "pins the displayed stable id when earlier messages are hidden" do
      pinned_message = {:assistant, "pinned context"}
      hidden_message = {:user, "hidden context"}
      visible_message = {:assistant, "visible target"}
      messages = [pinned_message, hidden_message, visible_message]
      message_ids = [{101, pinned_message}, {102, hidden_message}, {103, visible_message}]

      {:ok, session} =
        StubServer.start_link(
          messages: messages,
          message_ids: message_ids,
          pinned_ids: MapSet.new([101])
        )

      projection =
        TranscriptFixture.projection(messages,
          display_start_index: 2,
          message_ids: message_ids,
          pinned_ids: MapSet.new([101])
        )

      state =
        base_state(session: session)
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
            state,
            (fn ui ->
               panel =
                 ui.panel
                 |> Panel.install_transcript(projection, :keep)
                 |> Panel.set_scroll(Scroll.new(6))

               %{ui | panel: panel}
             end).(state.workspace.agent_ui)
          )
        end)

      AgentCommands.scope_pin_message(state)

      assert Session.pinned_ids(session) == MapSet.new([101, 103])
    end
  end

  # ── input_char / input_backspace / input_paste ───────────────────────────

  describe "input_char/2" do
    test "inserts character when panel is visible" do
      state = base_state(panel_visible: true, input_focused: true)
      new_state = AgentCommands.input_char(state, "a")

      assert MingaEditor.Agent.PromptBuffer.input_text(new_state.workspace.agent_ui.panel) == "a"
    end

    test "inserts multiple characters sequentially" do
      state = base_state(panel_visible: true, input_focused: true)

      state =
        state
        |> AgentCommands.input_char("h")
        |> AgentCommands.input_char("i")

      assert MingaEditor.Agent.PromptBuffer.input_text(state.workspace.agent_ui.panel) == "hi"
    end
  end

  describe "input_backspace/1" do
    test "deletes last character when panel is visible" do
      state = base_state(panel_visible: true, input_focused: true)

      state =
        state
        |> AgentCommands.input_char("a")
        |> AgentCommands.input_char("b")
        |> AgentCommands.input_backspace()

      assert MingaEditor.Agent.PromptBuffer.input_text(state.workspace.agent_ui.panel) == "a"
    end
  end

  describe "input_paste/2" do
    test "inserts pasted text when panel is visible" do
      state = base_state(panel_visible: true, input_focused: true)
      new_state = AgentCommands.input_paste(state, "pasted")

      text = MingaEditor.Agent.PromptBuffer.input_text(new_state.workspace.agent_ui.panel)
      assert text =~ "pasted"
    end
  end

  # ── abort_agent ──────────────────────────────────────────────────────────

  describe "abort_agent/1" do
    test "no-ops when no session exists" do
      state = base_state(session: nil)
      assert AgentCommands.abort_agent(state) == state
    end
  end

  describe "scope_ctrl_c/1" do
    test "stops a live turn, keeps queued messages queued and leaves Insert mode" do
      session =
        start_supervised!(
          {Session,
           provider: SessionSlowMockProvider, provider_opts: [test_pid: self()], persist?: false}
        )

      assert :ok = Session.subscribe(session)
      assert :ok = Session.send_prompt(session, "active turn")
      assert_receive {:agent_event, ^session, {:status_changed, :thinking}}, 1_000
      assert_receive {:agent_event, ^session, {:stop_target_changed, {_, _}} = stop_event}

      assert {:queued, :steering} = Session.send_prompt(session, "steering note")
      assert {:queued, :follow_up} = Session.queue_follow_up(session, "follow-up note")

      state =
        base_state(session: session)
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_state(
            state,
            (&AgentState.set_status(&1, :thinking)).(
              MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)
            )
          )
        end)
        |> MingaEditor.Agent.Events.dispatch(session, stop_event)
        |> enter_insert()

      new_state = AgentCommands.scope_ctrl_c(state)

      assert_receive :provider_abort_called, 1_000
      assert MingaEditor.Agent.PromptBuffer.input_text(new_state.workspace.agent_ui.panel) == ""
      assert Session.get_queued_messages(session) == {["steering note"], ["follow-up note"]}
      assert Session.status(session) == :stopped
      assert Minga.Editing.mode(new_state) == :normal
    end

    test "retries the provider and leaves Insert mode when the agent is in error state" do
      {:ok, session} = RestartStubSession.start_link(self())

      state =
        base_state(session: session)
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_state(
            state,
            (&AgentState.set_error(&1, "provider failed")).(
              MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)
            )
          )
        end)
        |> enter_insert()

      new_state = AgentCommands.scope_ctrl_c(state)

      assert_receive :restart_provider_called
      assert new_state.shell_runtime.state.notice.message == "Agent provider restarted"
      assert Minga.Editing.mode(new_state) == :normal
    end
  end

  defp enter_insert(state) do
    %{state | workspace: MingaEditor.Session.State.transition_mode(state.workspace, :insert)}
  end

  # ── ensure_agent_session ─────────────────────────────────────────────────

  describe "ensure_agent_session/1" do
    test "no-ops when session already exists" do
      fake_pid = spawn(fn -> :timer.sleep(:infinity) end)
      state = base_state(session: fake_pid)
      assert AgentCommands.ensure_agent_session(state) == state
    end
  end

  # ── cycle_thinking_level ─────────────────────────────────────────────────

  describe "cycle_thinking_level/1" do
    test "sets status message when no session exists" do
      state = base_state(session: nil)
      new_state = AgentCommands.cycle_thinking_level(state)

      assert new_state.shell_runtime.state.notice.message =~ "No agent session"
    end
  end

  describe "set_thinking_level/2" do
    test "updates the agent UI thinking level" do
      state = base_state()
      new_state = AgentCommands.set_thinking_level(state, "high")

      assert new_state.workspace.agent_ui.panel.thinking_level == "high"
      assert new_state.shell_runtime.state.notice.message == "Thinking: high"
    end

    test "sets status message when no session exists" do
      state = base_state(session: nil)
      new_state = AgentCommands.set_thinking_level(state, "high")

      assert new_state.shell_runtime.state.notice.message =~ "No agent session"
    end
  end

  describe "thinking command surface" do
    test "agent_pick_thinking opens the thinking picker with the current level" do
      selection =
        MingaAgent.Test.ModelSelectionFixture.selection(
          reasoning: %{effort: "low", options: ["off", "low", "high"]}
        )

      session = start_supervised!({RestorableModelSession, selection})
      state = base_state(session: session)

      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
          state,
          (&UIState.set_thinking_level(&1, "low")).(state.workspace.agent_ui)
        )

      command = command!(:agent_pick_thinking)

      new_state = command.execute.(state)

      assert {:picker, %{picker_ui: picker_ui}} = new_state.shell_runtime.state.modal
      assert picker_ui.source == MingaEditor.UI.Picker.ThinkingLevelSource
    end

    test "agent_pick_thinking shows status when no session exists" do
      state = base_state(session: nil)
      command = command!(:agent_pick_thinking)

      new_state = command.execute.(state)

      assert new_state.shell_runtime.state.notice.message =~ "No agent session"
    end

    test "agent_thinking_* commands set fixed levels" do
      for {command_name, expected_level} <- [
            agent_thinking_off: "off",
            agent_thinking_low: "low",
            agent_thinking_medium: "medium",
            agent_thinking_high: "high"
          ] do
        new_state = command!(command_name).execute.(base_state())

        assert new_state.workspace.agent_ui.panel.thinking_level == expected_level
        assert new_state.shell_runtime.state.notice.message == "Thinking: #{expected_level}"
      end
    end
  end

  describe "open_session/3" do
    test "synchronizes the panel from the restored session selection" do
      selection =
        ModelSelectionFixture.selection(
          display_name: "Restored Model",
          model_provider: "anthropic",
          reasoning: %{effort: "low", options: ["off", "low", "high"]}
        )

      {:ok, session} = RestorableModelSession.start_link(selection)

      original = base_state(session: session)
      ui = original.workspace.agent_ui

      timeline =
        MingaEditor.Agent.EditTimeline.recover_files(ui.view.edit_timeline, %{"old.ex" => 1})

      review = MingaEditor.Agent.DiffReview.new("old.ex", "before", "after")
      preview = MingaEditor.Agent.View.Preview.set_diff(ui.view.preview, review)

      ui =
        ui
        |> MingaEditor.Agent.UIState.replace_edit_timeline(timeline)
        |> MingaEditor.Agent.UIState.replace_preview(preview)

      original = MingaEditor.Shell.Traditional.Workflow.install_agent_ui(original, ui)

      state =
        original
        |> with_model_name("Previous Model")
        |> AgentCommands.open_session("saved-session")
        |> AgentSessionStart.settle_follow_ups()

      assert state.workspace.agent_ui.panel.model_name == "Restored Model"
      assert state.workspace.agent_ui.panel.provider_name == "anthropic"
      assert state.workspace.agent_ui.panel.thinking_level == "low"

      refute MingaEditor.Agent.EditTimeline.changed_file?(
               state.workspace.agent_ui.view.edit_timeline,
               "old.ex"
             )

      assert MingaEditor.Agent.View.Preview.diff_review(state.workspace.agent_ui.view.preview) ==
               nil
    end
  end

  describe "set_model/2" do
    test "preserves the prior model and shows an actionable rejection" do
      message = "Model \"missing\" is unavailable. Open /model and choose an exact route."
      session = start_supervised!({RejectingModelSession, message})
      task_supervisor = start_supervised!({Task.Supervisor, []})
      scheduler = start_supervised!({EffectScheduler, task_supervisor: task_supervisor})
      :ok = EffectScheduler.attach(scheduler, self())

      connection = %ConnectionSnapshot{
        target: ConnectionTarget.new(session, "model-command-test", nil, make_ref()),
        credential_readiness: :configured,
        model_selection: nil,
        provider_phase: :running,
        operation: :idle,
        problem: nil
      }

      state = base_state(session: session)

      ui =
        state.workspace.agent_ui
        |> UIState.project_connection(connection)
        |> UIState.set_model_name("Prior Model")

      state =
        %{
          state
          | effect_scheduler: scheduler,
            frontend: %Frontend{port_manager: nil, rendering: :disabled}
        }
        |> Workflow.install_agent_ui(ui)

      state = AgentCommands.set_model(state, "missing")
      assert_receive {:effect_result, ^scheduler, %Outcome{} = outcome}, 1_000

      assert {:noreply, state} =
               MingaEditor.handle_info({:effect_result, scheduler, outcome}, state)

      assert state.workspace.agent_ui.panel.model_name == "Prior Model"
      assert state.shell_runtime.state.notice.message == message
    end

    test "does not change the visible model without a validating session" do
      state = base_state(session: nil) |> with_model_name("Prior Model")

      state = AgentCommands.set_model(state, "unvalidated")

      assert state.workspace.agent_ui.panel.model_name == "Prior Model"
      assert state.shell_runtime.state.notice.message =~ "No agent session"
    end
  end

  # ── scope_* guard functions ──────────────────────────────────────────────
  # These functions guard on agentic/panel state. Test the guard behavior.

  describe "scope_focus_input/1" do
    test "focuses the panel input" do
      state = base_state(panel_visible: true, input_focused: false)
      new_state = AgentCommands.scope_focus_input(state)

      assert new_state.workspace.agent_ui.panel.input_focused == true
    end
  end

  describe "scope_switch_focus/1" do
    test "switches from chat to the retained review" do
      state = base_state(panel_visible: true)

      preview =
        MingaEditor.Agent.View.Preview.set_diff(
          MingaEditor.Agent.View.Preview.new(),
          MingaEditor.Agent.DiffReview.new("selected.ex", "before", "after")
        )

      view =
        state.workspace.agent_ui.view
        |> View.activate(nil, nil)
        |> View.replace_preview(preview)
        |> View.set_focus(:chat)

      state = MingaEditor.Shell.Traditional.Workflow.install_agent_view(state, view)

      new_state = AgentCommands.scope_switch_focus(state)

      assert new_state.workspace.agent_ui.view |> View.focus() == :file_viewer
    end

    test "switches from non-chat back to chat" do
      state = base_state(panel_visible: true)

      view =
        state.workspace.agent_ui.view |> View.activate(nil, nil) |> View.set_focus(:file_viewer)

      state = MingaEditor.Shell.Traditional.Workflow.install_agent_view(state, view)

      new_state = AgentCommands.scope_switch_focus(state)

      assert new_state.workspace.agent_ui.view |> View.focus() == :chat
    end
  end

  # ── toggle_paste_expand ──────────────────────────────────────────────────

  describe "toggle_paste_expand/1" do
    test "does not crash on empty input" do
      state = base_state(panel_visible: true, input_focused: true)
      new_state = AgentCommands.toggle_paste_expand(state)

      # Should not crash, input stays the same
      assert MingaEditor.Agent.PromptBuffer.input_text(new_state.workspace.agent_ui.panel) == ""
    end
  end

  # ── new_agent_session ────────────────────────────────────────────────────

  describe "new_agent_session/1" do
    test "resets agent state for a fresh session" do
      state = base_state()
      # Set some agent state
      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_state(
          state,
          (fn a -> %{a | error: "old error"} end).(
            MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)
          )
        )

      new_state = AgentCommands.new_agent_session(state)

      # Error should be cleared
      assert MingaEditor.Shell.Traditional.State.agent(new_state.shell_runtime.state).error == nil
    end

    test "creates a fresh semantic agent workspace for the new session" do
      state = base_state()

      new_state = AgentCommands.new_agent_session(state)

      {_win_id, agent_window} =
        MingaEditor.Session.State.find_agent_chat_window(new_state.workspace)

      assert agent_window.content == {:agent_chat, :semantic}
      assert new_state.workspace.buffers.active == nil
      assert new_state.workspace.keymap_scope == :agent
      assert new_state.workspace.editing.mode == :insert
      assert new_state.workspace.agent_ui.panel.visible
      assert new_state.workspace.agent_ui.panel.input_focused
      prompt = new_state.workspace.agent_ui.panel.prompt_buffer
      assert is_pid(prompt)
      original = state.workspace.buffers.active
      original_text = Minga.Buffer.content(original)

      assert {:handled, typed} = MingaEditor.Input.AgentPanel.handle_key(new_state, ?X, 0)
      assert Minga.Buffer.content(prompt) == "X"
      assert typed.workspace.buffers.active == nil
      assert Minga.Buffer.content(original) == original_text
    end

    test "creates an active agent workspace with no file context" do
      state = source_workspace_state()
      source_workspace = TabBar.get_workspace(state.shell_runtime.state.tab_bar, 0)

      new_state = state |> AgentCommands.new_agent_session() |> AgentSessionStart.settle()
      tab_bar = new_state.shell_runtime.state.tab_bar
      active_workspace = TabBar.active_workspace(tab_bar)

      assert active_workspace.kind == :agent
      assert active_workspace.files == []
      assert %WorkspaceAgent{session: session} = active_workspace.payload
      assert is_pid(session)
      assert MingaEditor.Shell.Runtime.active_tab_kind(new_state.shell_runtime) == :agent
      assert new_state.workspace.buffers.active == nil
      manual_workspace = TabBar.get_workspace(tab_bar, 0)
      assert manual_workspace.files == source_workspace.files
      assert manual_workspace.payload == source_workspace.payload
      assert %TabAgent{session: ^session} = TabBar.active(tab_bar).payload
    end

    test "creating sessions beside restored workspaces preserves unique ownership and independent drafts" do
      registry = :"#{__MODULE__}.draft_options.#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :duplicate, name: registry})

      options =
        start_supervised!({Minga.Config.Options, name: nil, events_registry: registry})

      assert {:ok, "test:test-model"} =
               Minga.Config.Options.set(options, :agent_model, "test:test-model")

      restored_workspaces =
        for id <- 1..2 do
          id
          |> MingaEditor.State.Workspace.new_agent("Restored #{id}")
          |> MingaEditor.State.Workspace.set_agent_ui(UIState.new())
        end

      tab_bar = TabBar.restore_workspaces(TabBar.new_empty(nil), restored_workspaces, nil)

      state =
        %EditorState{
          frontend: %Frontend{port_manager: nil},
          workspace:
            %WorkspaceState{}
            |> WorkspaceState.set_windows(
              Windows.add_window(%Windows{}, Window.new_agent_chat(1, 24, 80))
            )
            |> WorkspaceState.enter_empty_state(),
          interaction: Interaction.new(options_server: options),
          # Keys in this test go through the input handlers too: a sidebar table of its own (#4271).
          extension_surfaces:
            MingaEditor.State.ExtensionSurfaces.new(sidebar_registry: private_sidebar_registry()),
          shell_runtime:
            Runtime.new(Runtime.default_entry(), %MingaEditor.Shell.Traditional.State{})
        }
        |> install_tab_bar(tab_bar)
        |> with_agent_ingest()

      state_a =
        state |> MingaEditor.Commands.execute(:agent_new_session) |> AgentSessionStart.settle()

      tab_a = Runtime.active_tab(state_a.shell_runtime)
      session_a = Runtime.active_session(state_a.shell_runtime)
      prompt_a = state_a.workspace.agent_ui.panel.prompt_buffer

      on_exit(fn ->
        stop_owned_prompt(prompt_a)
        MingaAgent.SessionManager.stop_session_by_pid(session_a)
      end)

      owning_workspaces = fn state, session ->
        state.shell_runtime.state.tab_bar.workspaces
        |> Enum.filter(&match?(%{payload: %WorkspaceAgent{session: ^session}}, &1))
        |> Enum.map(& &1.id)
      end

      assert owning_workspaces.(state_a, session_a) == [tab_a.group_id]

      assert :ok =
               Session.seed_messages(session_a, [
                 {:user, "Focus question"},
                 {:assistant, "Focus answer"}
               ])

      assert {:handled, state_a} =
               MingaEditor.Input.AgentPanel.handle_paste(state_a, "keyboard draft")

      state_a = MingaEditor.Input.Router.route_key(state_a, 27, 0)
      state_a = MingaEditor.Commands.execute(state_a, :agent_close)
      assert state_a.workspace.keymap_scope == :agent
      assert View.active?(state_a.workspace.agent_ui.view)

      assert MingaEditor.Agent.PromptBuffer.prompt_text(state_a.workspace.agent_ui) ==
               "keyboard draft"

      {:links, links_before} = Process.info(self(), :links)

      state_b =
        state_a
        |> MingaEditor.Commands.execute(:agent_new_session)
        |> AgentSessionStart.settle()

      tab_b = Runtime.active_tab(state_b.shell_runtime)
      session_b = Runtime.active_session(state_b.shell_runtime)
      prompt_b = state_b.workspace.agent_ui.panel.prompt_buffer

      on_exit(fn ->
        stop_owned_prompt(prompt_b)
        MingaAgent.SessionManager.stop_session_by_pid(session_b)
      end)

      {:links, links_after} = Process.info(self(), :links)

      new_buffers =
        Enum.filter(links_after -- links_before, fn pid ->
          match?({BufferProcess, :init, _}, :proc_lib.translate_initial_call(pid))
        end)

      assert new_buffers == [prompt_b]
      assert Minga.Buffer.content(prompt_a) == "keyboard draft"

      refute session_a == session_b
      assert owning_workspaces.(state_b, session_a) == [tab_a.group_id]
      assert owning_workspaces.(state_b, session_b) == [tab_b.group_id]

      for restored <- restored_workspaces do
        workspace = TabBar.get_workspace(state_b.shell_runtime.state.tab_bar, restored.id)
        assert workspace.payload.session == nil
      end

      assert :ok =
               Session.seed_messages(session_b, [
                 {:user, "Draft question"},
                 {:assistant, "Draft answer"}
               ])

      assert {:handled, state_b} =
               MingaEditor.Input.AgentPanel.handle_paste(state_b, "preserved beta draft")

      state_b = MingaEditor.Input.Router.route_key(state_b, 27, 0)

      placeholder = MingaEditor.Commands.Workspace.workspace_next(state_b)
      assert Runtime.active_session(placeholder.shell_runtime) == nil

      active_a = MingaEditor.TabWorkflow.switch(placeholder, tab_a.id)
      assert Runtime.active_session(active_a.shell_runtime) == session_a
      active_a = collect_arrival(active_a, session_a)

      assert MingaEditor.Agent.PromptBuffer.prompt_text(active_a.workspace.agent_ui) ==
               "keyboard draft"

      assert active_a.workspace.keymap_scope == :agent
      assert active_a.workspace.agent_ui.panel.visible
      assert View.active?(active_a.workspace.agent_ui.view)
      messages = TranscriptFixture.messages(active_a.workspace.agent_ui.panel.transcript)
      assert {:assistant, "Focus answer"} in messages
      refute {:assistant, "Draft answer"} in messages

      assert WorkspaceState.active_window_struct(active_a.workspace).content ==
               {:agent_chat, :semantic}

      assert Minga.Editing.mode(active_a) == :normal
      {0, input_col} = MingaEditor.Agent.PromptBuffer.input_cursor(active_a.workspace.agent_ui)
      {before_cursor, after_cursor} = String.split_at("keyboard draft", input_col)

      active_a =
        active_a
        |> MingaEditor.Input.Router.route_key(?i, 0)
        |> MingaEditor.Input.Router.route_key(?!, 0)

      assert Runtime.active_tab(active_a.shell_runtime).id == tab_a.id
      assert Minga.Editing.mode(active_a) == :insert

      assert MingaEditor.Agent.PromptBuffer.prompt_text(active_a.workspace.agent_ui) ==
               before_cursor <> "!" <> after_cursor

      %{connection: %{target: history_target}} = Session.editor_snapshot(session_a)

      {active_a, revision} =
        PickerUI.open_loading(active_a, AgentHistorySource, %{
          origin: {tab_a.group_id, history_target},
          source: history_target,
          anchor: :tail
        })

      active_b = MingaEditor.TabWorkflow.switch(active_a, tab_b.id)
      assert Runtime.active_session(active_b.shell_runtime) == session_b
      active_b = collect_arrival(active_b, session_b)

      assert :stale =
               PickerUI.apply_fetch_result(
                 active_b,
                 AgentHistorySource,
                 revision,
                 {:error, "Late history result for the previous workspace"}
               )

      assert MingaEditor.Agent.PromptBuffer.prompt_text(active_b.workspace.agent_ui) ==
               "preserved beta draft"

      assert active_b.workspace.agent_ui.panel.visible
      assert View.active?(active_b.workspace.agent_ui.view)
      messages = TranscriptFixture.messages(active_b.workspace.agent_ui.panel.transcript)
      assert {:assistant, "Draft answer"} in messages
      refute {:assistant, "Focus answer"} in messages
    end

    defp with_catalog_scheduler(state) do
      tasks = start_supervised!(Task.Supervisor)
      scheduler = start_supervised!({EffectScheduler, task_supervisor: tasks})
      :ok = EffectScheduler.attach(scheduler, self())
      %{state | effect_scheduler: scheduler}
    end

    test "a completed cold action does not activate Agent after switching away" do
      state = with_catalog_scheduler(source_workspace_state())
      pending = CatalogStartup.defer(state, :new)

      assert_receive {:effect_result, scheduler, %Outcome{value: {:completed, :ready}} = outcome},
                     2_000

      other = pending |> AgentCommands.new_agent_session() |> AgentSessionStart.settle()
      session = Runtime.active_session(other.shell_runtime)
      assert :ok = EffectScheduler.claim(scheduler, outcome)

      {finished, %Outcome{value: {:stale, :agent_origin_changed}} = stale} =
        CatalogStartup.apply(other, outcome)

      EffectScheduler.finalize(scheduler, stale)
      assert is_pid(session)
      assert Runtime.active_session(finished.shell_runtime) == session
    end

    test "a deferred Agent start finishes in its departed workspace without taking focus" do
      state = source_workspace_state() |> with_catalog_scheduler() |> with_agent_ingest()
      tabs = state.shell_runtime.state.tab_bar
      source_id = tabs.active_id

      {tabs, tab} =
        MingaEditor.TabWorkflow.insert_agent(
          tabs,
          "Starting",
          state.frontend.terminal_viewport,
          nil
        )

      {tabs, workspace} = TabBar.add_workspace(tabs, "Starting")

      pending =
        state
        |> install_tab_bar(TabBar.move_tab_to_workspace(tabs, tab.id, workspace.id))
        |> MingaEditor.TabWorkflow.switch(tab.id)

      pending =
        MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
          pending,
          MingaEditor.Agent.PromptBuffer.set_prompt_text(
            pending.workspace.agent_ui,
            "draft before leaving"
          )
        )
        |> CatalogStartup.defer({:start, workspace.id, false, false, nil})

      departed = MingaEditor.TabWorkflow.switch(pending, source_id)

      assert_receive {:effect_result, scheduler, %Outcome{value: {:completed, :ready}} = outcome},
                     20_000

      assert :ok = EffectScheduler.claim(scheduler, outcome)

      failure = Outcome.failed(outcome.request, {:catalog_probe, :disk_full})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(self(), {:applied, CatalogStartup.apply(departed, failure)})
        end)

      assert_received {:applied, {failed, ^failure}}
      # The tab shows a plain sentence; the raw reason stays in the log.
      assert log =~ "Model catalog load failed: {:catalog_probe, :disk_full}"
      assert Runtime.active_tab(failed.shell_runtime).id == source_id

      failed = MingaEditor.TabWorkflow.switch(failed, tab.id)

      assert %{
               visible?: true,
               lifecycle: {:failed, "The model catalog could not be loaded.", %{kind: :retry}},
               prompt: "draft before leaving"
             } =
               Minga.Test.AgentWorkflowDriver.chat_model(failed)

      {started, ^outcome} = CatalogStartup.apply(departed, outcome)
      EffectScheduler.finalize(scheduler, outcome)
      assert Runtime.active_tab(started.shell_runtime).id == source_id

      {^started, %Outcome{value: {:stale, :agent_origin_changed}}} =
        CatalogStartup.apply(started, outcome)

      started = AgentSessionStart.settle(started)
      assert Runtime.active_tab(started.shell_runtime).id == source_id
      returned = MingaEditor.TabWorkflow.switch(started, tab.id)
      session = Runtime.active_session(returned.shell_runtime)
      assert is_pid(session)
      on_exit(fn -> MingaAgent.SessionManager.stop_session_by_pid(session) end)
      returned = collect_arrival(returned, session)

      assert %{visible?: true, lifecycle: :conversation, prompt: "draft before leaving"} =
               Minga.Test.AgentWorkflowDriver.chat_model(returned)
    end

    defp with_active_agent_workspace(state) do
      tabs = state.shell_runtime.state.tab_bar

      {tabs, tab} =
        MingaEditor.TabWorkflow.insert_agent(
          tabs,
          "Starting",
          state.frontend.terminal_viewport,
          nil
        )

      {tabs, workspace} = TabBar.add_workspace(tabs, "Starting")

      state =
        state
        |> install_tab_bar(TabBar.move_tab_to_workspace(tabs, tab.id, workspace.id))
        |> MingaEditor.TabWorkflow.switch(tab.id)

      {state, tab, workspace}
    end

    test "a deferred Agent start ignores catalog progress and replaced starts until the load settles" do
      {pending, _tab, workspace} =
        source_workspace_state()
        |> with_catalog_scheduler()
        |> with_agent_ingest()
        |> with_active_agent_workspace()

      pending =
        MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
          pending,
          MingaEditor.Agent.PromptBuffer.set_prompt_text(pending.workspace.agent_ui, "keep me")
        )
        |> CatalogStartup.defer({:start, workspace.id, false, false, nil})

      assert_receive {:effect_result, scheduler, %Outcome{value: {:completed, :ready}} = outcome},
                     20_000

      assert :ok = EffectScheduler.claim(scheduler, outcome)
      request = outcome.request

      not_terminal = [
        Outcome.running(request),
        Outcome.queued(request, 1, 1),
        Outcome.canceled(request, :superseded),
        Outcome.stale(outcome, :superseded)
      ]

      still_starting =
        Enum.reduce(not_terminal, pending, fn progress, acc ->
          {next, ^progress} = CatalogStartup.apply(acc, progress)
          next
        end)

      assert %{lifecycle: lifecycle, prompt: "keep me"} =
               Minga.Test.AgentWorkflowDriver.chat_model(still_starting)

      refute match?({:failed, _}, lifecycle)

      {started, ^outcome} = CatalogStartup.apply(still_starting, outcome)
      EffectScheduler.finalize(scheduler, outcome)
      started = AgentSessionStart.settle(started)
      session = Runtime.active_session(started.shell_runtime)
      assert is_pid(session)
      on_exit(fn -> MingaAgent.SessionManager.stop_session_by_pid(session) end)

      assert %{lifecycle: started_lifecycle, prompt: "keep me"} =
               Minga.Test.AgentWorkflowDriver.chat_model(started)

      refute match?({:failed, _}, started_lifecycle)
    end

    test "Retry runs a failed start again in the same tab and keeps the draft" do
      {pending, tab, workspace} =
        source_workspace_state()
        |> with_catalog_scheduler()
        |> with_agent_ingest()
        |> with_active_agent_workspace()

      pending =
        MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
          pending,
          MingaEditor.Agent.PromptBuffer.set_prompt_text(
            pending.workspace.agent_ui,
            "draft to keep"
          )
        )
        |> CatalogStartup.defer({:start, workspace.id, false, false, nil})

      assert_receive {:effect_result, scheduler, %Outcome{value: {:completed, :ready}} = outcome},
                     20_000

      assert :ok = EffectScheduler.claim(scheduler, outcome)
      failure = Outcome.failed(outcome.request, :model_catalog_unavailable)
      {failed, ^failure} = CatalogStartup.apply(pending, failure)
      EffectScheduler.finalize(scheduler, failure)

      assert {:failed, %StartFailure{remedy: {:retry, %StartRequest{}}}} =
               failed.workspace.agent_ui.chat_lifecycle

      # Retry does not mark the Agent errored and does not reset the tab.
      assert MingaEditor.Shell.Traditional.State.agent(failed.shell_runtime.state).error == nil

      retried = MingaEditor.Commands.execute(failed, :agent_retry_start)
      assert retried.workspace.agent_ui.chat_lifecycle == :starting
      assert Runtime.active_tab(retried.shell_runtime).id == tab.id

      assert MingaEditor.Agent.PromptBuffer.prompt_text(retried.workspace.agent_ui) ==
               "draft to keep"

      started = AgentSessionStart.settle(retried)
      session = Runtime.active_session(started.shell_runtime)
      assert is_pid(session)
      on_exit(fn -> MingaAgent.SessionManager.stop_session_by_pid(session) end)

      assert MingaEditor.Agent.PromptBuffer.prompt_text(started.workspace.agent_ui) ==
               "draft to keep"
    end

    # A visible panel routes a focused composer's keys through the Agent panel
    # handler; a hidden one leaves them to the scoped handler. Both must agree.
    defp failed_composer(state, failure, draft, visible? \\ true) do
      ui =
        state.workspace.agent_ui
        |> MingaEditor.Agent.PromptBuffer.set_prompt_text(draft)
        |> UIState.fail_start(failure)

      ui = if ui.panel.visible == visible?, do: ui, else: UIState.toggle(ui)

      state |> Workflow.install_agent_ui(ui) |> AgentCommands.scope_focus_input()
    end

    # The Editor's own key entry: every input handler in precedence order.
    defp press_enter(state), do: MingaEditor.Input.Router.dispatch(state, 13, 0)

    # This failure has been seen without a reproduction (#4271): the lifecycle stayed failed after Enter.
    # The message names every input the retry decision reads, so the next occurrence shows which one was wrong.
    defp retry_diagnosis(before, retried, iteration) do
      """
      Enter did not move the failed start to :starting (#{inspect(iteration)}).
      chat_lifecycle after Enter: #{inspect(retried.workspace.agent_ui.chat_lifecycle)}
      start remedy before Enter: #{inspect(UIState.start_remedy(before.workspace.agent_ui))}
      handler that claims Enter: #{inspect(MingaEditor.Input.Router.claiming_handler(before, 13, 0))}
      active workspace before: #{active_workspace_summary(before)}
      active workspace after: #{active_workspace_summary(retried)}
      Enter replaced the shell state: #{before.shell_runtime.state != retried.shell_runtime.state}
      starts in flight before: #{start_phases(before)}
      starts in flight after: #{start_phases(retried)}
      shell entry held by the state: #{inspect(retried.shell_runtime.entry)}
      shell entry in the registry: #{inspect(MingaEditor.Shell.Registry.get(:traditional))}
      model catalog epoch: #{LLMDB.epoch()}
      editing mode before: #{inspect(before.workspace.editing.mode)}, keymap scope: #{inspect(before.workspace.keymap_scope)}
      notice after: #{inspect(MingaEditor.Shell.Traditional.NoticeWorkflow.message(retried))}
      """
    end

    defp active_workspace_summary(state) do
      case state.shell_runtime.state.tab_bar do
        %TabBar{} = tabs -> inspect(TabBar.active_workspace(tabs), limit: 16)
        other -> "no tab bar: #{inspect(other)}"
      end
    end

    defp start_phases(state) do
      inspect(
        for {_token, start} <- state.agent_connection.session_starts,
            do: {start.workspace, start.phase}
      )
    end

    test "Enter in the composer's Insert adds a newline and does not retry a failed start" do
      {state, _tab, _workspace} = with_active_agent_workspace(source_workspace_state())
      failure = StartFailure.timed_out(StartRequest.new(false, false, nil))
      composer = failed_composer(state, failure, "draft to keep")
      assert Minga.Editing.inserting?(composer)

      pressed = press_enter(composer)

      assert pressed.workspace.agent_ui.chat_lifecycle == {:failed, failure}
      assert MingaEditor.Agent.PromptBuffer.prompt_text(pressed.workspace.agent_ui) =~ "\n"
    end

    test "Enter in the composer's Normal mode retries a failed start and keeps the draft" do
      {state, tab, _workspace} =
        source_workspace_state()
        |> with_catalog_scheduler()
        |> with_agent_ingest()
        |> with_active_agent_workspace()

      for visible? <- [true, false] do
        failure = StartFailure.timed_out(StartRequest.new(false, false, nil))

        composer =
          state
          |> failed_composer(failure, "draft to keep", visible?)
          |> AgentCommands.input_to_normal()

        assert MingaEditor.Agent.UIState.start_remedy(composer.workspace.agent_ui) == :retry
        refute Minga.Editing.inserting?(composer)
        assert composer.workspace.agent_ui.panel.visible == visible?
        assert composer.workspace.agent_ui.panel.input_focused
        retried = press_enter(composer)

        # Built only on failure: the diagnosis dispatches Enter again to name the claiming handler.
        if retried.workspace.agent_ui.chat_lifecycle != :starting do
          flunk(retry_diagnosis(composer, retried, visible?: visible?))
        end

        assert Runtime.active_tab(retried.shell_runtime).id == tab.id

        assert MingaEditor.Agent.PromptBuffer.prompt_text(retried.workspace.agent_ui) ==
                 "draft to keep"

        started = AgentSessionStart.settle(retried)

        if session = Runtime.active_session(started.shell_runtime) do
          MingaAgent.SessionManager.stop_session_by_pid(session)
        end

        # The draft is not sent after the retry; it waits for the next Enter.
        assert MingaEditor.Agent.PromptBuffer.prompt_text(started.workspace.agent_ui) ==
                 "draft to keep"
      end
    end

    test "Enter in the composer opens provider setup when setup is the remedy" do
      {state, _tab, _workspace} = with_active_agent_workspace(source_workspace_state())

      composer =
        state
        |> failed_composer(StartFailure.missing_credentials(), "draft to keep")
        |> AgentCommands.input_to_normal()

      opened = press_enter(composer)

      # Without a session the model picker reports why it cannot open.
      assert %{message: "Connection details are unavailable." <> _} =
               opened.workspace.agent_ui.view.toast

      assert opened.workspace.agent_ui.chat_lifecycle ==
               composer.workspace.agent_ui.chat_lifecycle

      assert MingaEditor.Agent.PromptBuffer.prompt_text(opened.workspace.agent_ui) ==
               "draft to keep"
    end

    test "a remote session crash offers no remedy and Enter is not taken over" do
      {state, _tab, _workspace} = with_active_agent_workspace(source_workspace_state())
      node = "remote@host"

      remote =
        :erlang.binary_to_term(
          <<131, 88, 119, byte_size(node), node::binary, 1::32, 0::32, 1::32>>
        )

      failure = StartFailure.session_crashed(remote)
      assert failure.remedy == nil
      composer = state |> failed_composer(failure, "hello") |> AgentCommands.input_to_normal()
      assert UIState.start_remedy(composer.workspace.agent_ui) == nil

      submitted = press_enter(composer)

      assert submitted.workspace.agent_ui.chat_lifecycle == {:failed, failure}
      assert MingaEditor.Agent.PromptBuffer.prompt_text(submitted.workspace.agent_ui) == "hello"
      assert AgentSession.run_start_remedy(composer) == composer
    end

    test "Retry does nothing unless the active tab shows a retryable failed start" do
      {state, _tab, _workspace} = with_active_agent_workspace(source_workspace_state())

      for lifecycle <- [
            :starting,
            :unavailable,
            {:conversation, self()},
            {:failed, StartFailure.missing_credentials()}
          ] do
        ui = UIState.restore_chat(state.workspace.agent_ui, lifecycle)
        shown = Workflow.install_agent_ui(state, ui)

        assert AgentSession.retry_start(shown) == shown
      end
    end

    test "a pending file-to-Agent toggle keeps the file editable and can retry after failure" do
      state = with_catalog_scheduler(source_workspace_state())
      file = state.workspace.buffers.active
      action = {:toggle, AgentCommands.catalog_destination(state)}
      pending = CatalogStartup.defer(state, action)
      assert Runtime.active_tab_kind(pending.shell_runtime) == :file
      assert AgentCommands.catalog_destination(pending) == :absent
      :ok = BufferProcess.insert_text(file, "edit while loading")

      assert_receive {:effect_result, scheduler, %Outcome{request: request} = outcome}, 2_000
      assert request.effect.action == action
      assert :ok = EffectScheduler.claim(scheduler, outcome)
      failed = Outcome.failed(request, :model_catalog_unavailable)
      {state, ^failed} = CatalogStartup.apply(pending, failed)
      EffectScheduler.finalize(scheduler, failed)
      assert Runtime.active_tab_kind(state.shell_runtime) == :file
      assert BufferProcess.content(file) =~ "edit while loading"

      state = CatalogStartup.defer(state, action)

      assert_receive {:effect_result, ^scheduler, %Outcome{value: {:completed, :ready}} = retry},
                     2_000

      assert :ok = EffectScheduler.claim(scheduler, retry)
      {opened, ^retry} = CatalogStartup.apply(state, retry)
      EffectScheduler.finalize(scheduler, retry)
      assert Runtime.active_tab_kind(opened.shell_runtime) == :agent
    end

    test "a cold restore does not replace an Agent destination created after admission" do
      state = with_catalog_scheduler(source_workspace_state())
      source_id = state.shell_runtime.state.tab_bar.active_id
      pending = CatalogStartup.defer(state, {:restore, :absent, "original-saved-id", nil, nil})

      assert_receive {:effect_result, scheduler, %Outcome{value: {:completed, :ready}} = outcome},
                     2_000

      opened = pending |> AgentCommands.new_agent_session() |> AgentSessionStart.settle()
      session = Runtime.active_session(opened.shell_runtime)
      assert is_pid(session)
      returned = MingaEditor.TabWorkflow.switch(opened, source_id)

      assert :ok = EffectScheduler.claim(scheduler, outcome)

      {finished, %Outcome{value: {:stale, :agent_origin_changed}} = stale} =
        CatalogStartup.apply(returned, outcome)

      EffectScheduler.finalize(scheduler, stale)
      assert Runtime.active_tab_kind(finished.shell_runtime) == :file
      assert {_tab, _owner, ^session} = AgentCommands.catalog_destination(finished)
    end

    test "new_agent_session from empty tab bar activates first real tab through workflow" do
      state = base_state()
      tab_bar = TabBar.new_empty("/tmp/minga-empty-launchpad")

      shell_state =
        MingaEditor.Shell.Traditional.State.install_tab_bar(
          Runtime.state(state.shell_runtime),
          tab_bar
        )

      state = %{
        state
        | workspace: WorkspaceState.enter_empty_state(state.workspace),
          shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)
      }

      new_state = state |> AgentCommands.new_agent_session() |> AgentSessionStart.settle()
      tab_bar = new_state.shell_runtime.state.tab_bar
      active_tab = TabBar.active(tab_bar)
      {_window_id, active_window} = WorkspaceState.find_agent_chat_window(new_state.workspace)
      active_workspace = TabBar.active_workspace(tab_bar)

      assert tab_bar.active_id == 1
      assert tab_bar.next_id == 2
      assert active_tab.kind == :agent
      assert Runtime.active_tab_kind(new_state.shell_runtime) == :agent
      assert new_state.workspace.buffers.active == nil
      assert MingaEditor.Window.Content.agent_chat?(active_window.content)
      assert %WorkspaceAgent{session: session} = active_workspace.payload
      assert is_pid(session)
      assert %TabAgent{session: ^session} = active_tab.payload
    end

    test "switching back to the source file tab restores file content" do
      state = source_workspace_state()
      file_tab_id = state.shell_runtime.state.tab_bar.active_id

      new_state = AgentCommands.new_agent_session(state)
      switched = MingaEditor.TabWorkflow.switch(new_state, file_tab_id)
      active_window = switched.workspace.windows.map[switched.workspace.windows.active]

      assert MingaEditor.Shell.Runtime.active_tab_kind(switched.shell_runtime) == :file
      assert active_window.content == {:buffer, switched.workspace.buffers.active}
      refute MingaEditor.Window.Content.agent_chat?(active_window.content)
    end

    test "switching to a file tab inside an agent workspace restores file content" do
      state = source_workspace_state()
      file_tab_id = state.shell_runtime.state.tab_bar.active_id
      file_tab = TabBar.get(state.shell_runtime.state.tab_bar, file_tab_id)

      new_state = AgentCommands.new_agent_session(state)
      agent_workspace_id = TabBar.active_workspace_id(new_state.shell_runtime.state.tab_bar)

      tab_bar =
        new_state.shell_runtime.state.tab_bar
        |> TabBar.move_tab_to_workspace(file_tab_id, agent_workspace_id)
        |> TabBar.update_context(file_tab_id, file_tab.context)

      switched =
        new_state
        |> then(fn root ->
          shell_state =
            MingaEditor.Shell.Traditional.State.install_tab_bar(
              MingaEditor.Shell.Runtime.state(root.shell_runtime),
              tab_bar
            )

          %{
            root
            | shell_runtime:
                MingaEditor.Shell.Runtime.install_traditional_state(
                  root.shell_runtime,
                  shell_state
                )
          }
        end)
        |> MingaEditor.TabWorkflow.switch(file_tab_id)

      active_window = switched.workspace.windows.map[switched.workspace.windows.active]

      assert TabBar.active_workspace_id(switched.shell_runtime.state.tab_bar) ==
               agent_workspace_id

      assert MingaEditor.Shell.Runtime.active_tab_kind(switched.shell_runtime) == :file
      assert active_window.content == {:buffer, switched.workspace.buffers.active}
      refute MingaEditor.Window.Content.agent_chat?(active_window.content)
    end

    test "creating from an existing agent workspace preserves the source tab context" do
      state = active_agent_workspace_state()
      old_tab = TabBar.active(state.shell_runtime.state.tab_bar)
      old_session = old_tab.payload.session

      new_state = AgentCommands.new_agent_session(state)
      tab_bar = new_state.shell_runtime.state.tab_bar
      updated_old_tab = TabBar.get(tab_bar, old_tab.id)
      old_context = TabContext.to_workspace_map(updated_old_tab.context)
      new_session = TabBar.active(tab_bar).payload.session

      assert old_context.buffers.active == nil
      assert old_session != nil
      assert new_session != old_session
      assert new_state.workspace.buffers.active == nil

      {_win_id, agent_window} =
        MingaEditor.Session.State.find_agent_chat_window(new_state.workspace)

      assert agent_window.content == {:agent_chat, :semantic}
    end

    test "background agent session creation does not switch active workspace" do
      state = source_workspace_with_background_agent_tab()
      source_active_id = state.shell_runtime.state.tab_bar.active_id
      source_workspace = TabBar.get_workspace(state.shell_runtime.state.tab_bar, 0)

      new_state = state |> AgentSession.start_agent_session() |> AgentSessionStart.settle()
      tab_bar = new_state.shell_runtime.state.tab_bar
      agent_workspaces = Enum.filter(tab_bar.workspaces, &(&1.kind == :agent))

      assert tab_bar.active_id == source_active_id
      assert TabBar.active_workspace_id(tab_bar) == 0
      manual_workspace = TabBar.get_workspace(tab_bar, 0)
      assert manual_workspace.files == source_workspace.files
      assert manual_workspace.payload == source_workspace.payload
      assert [%{files: [], payload: %WorkspaceAgent{session: session}}] = agent_workspaces
      assert is_pid(session)
    end

    test "starting from an active agent workspace preserves session UI and clears the active workspace payload" do
      state = active_agent_workspace_state()

      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
          state,
          state.workspace.agent_ui
          |> MingaEditor.Agent.PromptBuffer.ensure()
          |> MingaEditor.Agent.PromptBuffer.set_prompt_text("active draft")
        )

      new_state = state |> AgentSession.start_agent_session() |> AgentSessionStart.settle()
      active_workspace = TabBar.active_workspace(new_state.shell_runtime.state.tab_bar)

      assert MingaEditor.Agent.PromptBuffer.input_text(new_state.workspace.agent_ui.panel) ==
               "active draft"

      assert %WorkspaceAgent{agent_ui: nil, session: session} = active_workspace.payload
      assert is_pid(session)
    end

    test "an admitted agent workspace has a usable draft before its first focus" do
      state = active_agent_workspace_state()
      refute state.workspace.agent_ui.panel.input_focused
      state = MingaEditor.AgentLifecycle.maybe_start_session(state)
      prompt = state.workspace.agent_ui.panel.prompt_buffer
      assert Minga.Buffer.content(prompt) == ""
      assert state.workspace.editing.mode == :normal
      refute state.workspace.agent_ui.panel.input_focused

      Minga.Buffer.insert_text(prompt, "unfinished draft")
      cursor = Minga.Buffer.cursor(prompt)
      state = MingaEditor.AgentLifecycle.maybe_start_session(state)

      assert Minga.Buffer.content(state.workspace.agent_ui.panel.prompt_buffer) ==
               "unfinished draft"

      assert Minga.Buffer.cursor(state.workspace.agent_ui.panel.prompt_buffer) == cursor
    end
  end

  test "detach remote session command disconnects workspace payload and agent tab payload" do
    test_pid = self()

    Process.put(:minga_editor_remote_detach, fn remote_node, session_id ->
      send(test_pid, {:detach, remote_node, session_id})
      :ok
    end)

    on_exit(fn -> Process.delete(:minga_editor_remote_detach) end)

    state = base_state(session: nil)
    session_id = "session-1"

    remote_pid =
      :erlang.binary_to_term(<<131, 103, 100, 0, 11, "remote@stub", 0, 0, 0, 1, 0, 0, 0, 0, 1>>)

    tab_bar = state.shell_runtime.state.tab_bar
    workspace_id = TabBar.active_workspace_id(tab_bar)

    workspace =
      tab_bar
      |> TabBar.get_workspace(workspace_id)
      |> MingaEditor.State.Workspace.set_session(remote_pid)
      |> MingaEditor.State.Workspace.set_remote_session(
        MingaEditor.State.Workspace.RemoteSession.new("remote", session_id, :connected, 0)
      )

    state =
      install_tab_bar(
        state,
        TabBar.accept_workspace(tab_bar, workspace)
      )

    result = MingaEditor.Commands.execute(state, :detach_remote_session)

    assert_receive {:detach, :remote@stub, ^session_id}
    tab_bar = result.shell_runtime.state.tab_bar
    workspace = TabBar.get_workspace(tab_bar, workspace_id)
    assert workspace.payload.remote_session.connection_status == :disconnected
    assert TabBar.get(tab_bar, 1).payload.connection_status == :disconnected
  end

  # ── cycle_agent_tabs ─────────────────────────────────────────────────────

  describe "cycle_agent_tabs/1" do
    test "creates an agent tab when none exist" do
      state = base_state()
      new_state = AgentCommands.cycle_agent_tabs(state)

      agent_tabs = TabBar.filter_by_kind(new_state.shell_runtime.state.tab_bar, :agent)
      assert agent_tabs != []
    end
  end

  defp with_agent_ingest(state) do
    ingest = start_supervised!({Ingest, editor: self()})
    %{state | agent_connection: AgentConnection.connect_ingest(state.agent_connection, ingest)}
  end

  defp collect_arrival(state, session) do
    assert_receive {:agent_event, ^session, {:editor_arrival_ready, _, _}} = capture, 5_000
    {:noreply, state} = MingaEditor.handle_info(capture, state)
    state
  end

  defp replace_panel(state, transition) do
    MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
      state,
      transition.(state.workspace.agent_ui.panel)
    )
  end
end
