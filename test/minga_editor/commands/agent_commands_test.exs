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
  alias Minga.Editing.Scroll
  alias MingaEditor.Agent.Transcript
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.UIState.View
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Project.FileRef
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
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
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias Minga.Test.SessionSlowMockProvider
  alias Minga.Test.StubServer

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
    def abort(pid), do: GenServer.cast(pid, :abort)

    @impl MingaAgent.Provider
    def new_session(pid), do: GenServer.cast(pid, :new_session)

    @impl MingaAgent.Provider
    def seed_messages(_pid, _messages), do: :ok

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

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl GenServer
    def init(opts), do: {:ok, Map.new(opts)}

    @impl GenServer
    def handle_call(:get_provider, _from, state), do: {:reply, Map.get(state, :provider), state}

    def handle_call(:editor_snapshot, _from, state) do
      snapshot = %{
        status: Map.get(state, :status, :idle),
        pending_approval: nil,
        error: Map.get(state, :error),
        active_tool_name: nil,
        credentials_configured: Map.get(state, :credentials_configured, true)
      }

      {:reply, snapshot, state}
    end

    def handle_call({:send_prompt, content}, _from, state) do
      if notify = Map.get(state, :notify) do
        send(notify, {:readiness_session_prompt, content})
      end

      {:reply, Map.get(state, :send_prompt_result, :ok), state}
    end
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

      new_state = AgentCommands.submit_prompt(state)

      assert new_state.workspace.agent_ui.panel.prompt_history == []
      assert MingaEditor.Agent.PromptBuffer.prompt_text(new_state.workspace.agent_ui.panel) == ""
    end

    test "unknown slash command preserves draft and reports the error in chat" do
      {:ok, session} = StubServer.start_link(notify: self())

      state =
        base_state(session: session)
        |> AgentCommands.input_paste("/modle")

      new_state = AgentCommands.submit_prompt(state)

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

      new_state = AgentCommands.submit_prompt(state)

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

      new_state = AgentCommands.submit_prompt(state)

      assert new_state.shell_runtime.state.notice.message =~ "No agent session"

      assert MingaEditor.Agent.PromptBuffer.prompt_text(new_state.workspace.agent_ui.panel) ==
               "hello agent"
    end

    test "blocks submit as credentials missing when the local session reports credentials are not configured" do
      {:ok, session} = ReadinessSession.start_link(provider: nil, credentials_configured: false)

      state =
        base_state(session: session)
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
        |> replace_panel(fn panel ->
          panel
          |> Panel.set_credentials_configured(true)
          |> Panel.set_model_name("anthropic:claude-sonnet-4-20250514")
          |> Panel.set_provider_name("anthropic")
        end)

      new_state = AgentCommands.submit_prompt(state)

      assert new_state.shell_runtime.state.notice.message =~
               "No provider credentials are configured for this model"

      assert MingaEditor.Agent.PromptBuffer.prompt_text(new_state.workspace.agent_ui.panel) ==
               "draft prompt"
    end

    test "blocks submit as starting when credentials exist but no provider is attached yet" do
      {:ok, session} = ReadinessSession.start_link(provider: nil)

      state =
        base_state(session: session)
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
        |> replace_panel(fn panel ->
          panel
          |> Panel.set_credentials_configured(true)
          |> Panel.set_model_name("anthropic:claude-sonnet-4-20250514")
          |> Panel.set_provider_name("anthropic")
        end)

      new_state = AgentCommands.submit_prompt(state)

      assert new_state.shell_runtime.state.notice.message =~ "Agent provider still starting"

      assert MingaEditor.Agent.PromptBuffer.prompt_text(new_state.workspace.agent_ui.panel) ==
               "draft prompt"
    end

    test "blocks submit with concrete startup failure when provider startup failed" do
      {:ok, session} = ReadinessSession.start_link(provider: nil, error: "boom")

      state =
        base_state(session: session)
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
        |> replace_panel(fn panel ->
          panel
          |> Panel.set_credentials_configured(true)
          |> Panel.set_model_name("anthropic:claude-sonnet-4-20250514")
          |> Panel.set_provider_name("anthropic")
        end)

      new_state = AgentCommands.submit_prompt(state)

      assert new_state.shell_runtime.state.notice.message ==
               "Failed to start agent: boom. Your prompt was preserved."

      assert MingaEditor.Agent.PromptBuffer.prompt_text(new_state.workspace.agent_ui.panel) ==
               "draft prompt"
    end

    test "ready provider still sends and clears a normal prompt" do
      {:ok, session} = ReadinessSession.start_link(provider: self(), notify: self())

      state =
        base_state(session: session)
        |> then(fn state ->
          MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
            state,
            (fn ui ->
               ui = MingaEditor.Agent.PromptBuffer.ensure(ui)
               BufferProcess.replace_content(ui.panel.prompt_buffer, "ready prompt")
               ui
             end).(state.workspace.agent_ui)
          )
        end)
        |> replace_panel(fn panel ->
          panel
          |> Panel.set_credentials_configured(true)
          |> Panel.set_model_name("anthropic:claude-sonnet-4-20250514")
          |> Panel.set_provider_name("anthropic")
        end)

      new_state = AgentCommands.submit_prompt(state)

      assert_receive {:readiness_session_prompt, "ready prompt"}
      assert MingaEditor.Agent.PromptBuffer.prompt_text(new_state.workspace.agent_ui.panel) == ""
    end

    test "unresolved file mention preserves the prompt and does not send" do
      {:ok, session} = ReadinessSession.start_link(provider: self(), notify: self())

      state =
        base_state(session: session)
        |> AgentCommands.input_paste("@missing.ex explain")
        |> replace_panel(fn panel ->
          panel
          |> Panel.set_credentials_configured(true)
          |> Panel.set_model_name("anthropic:claude-sonnet-4-20250514")
          |> Panel.set_provider_name("anthropic")
        end)

      new_state = AgentCommands.submit_prompt(state)

      assert new_state.shell_runtime.state.notice.message =~ "Cannot resolve file mentions"

      assert MingaEditor.Agent.PromptBuffer.prompt_text(new_state.workspace.agent_ui.panel) ==
               "@missing.ex explain"

      refute_receive {:readiness_session_prompt, _prompt}
    end

    test "ready local provider sends even when panel credentials cache is stale" do
      {:ok, session} =
        ReadinessSession.start_link(
          provider: self(),
          notify: self(),
          credentials_configured: true
        )

      state =
        base_state(session: session)
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

      new_state = AgentCommands.submit_prompt(state)

      assert_receive {:readiness_session_prompt, "stale panel prompt"}
      assert is_nil(new_state.shell_runtime.state.notice.message)
      assert MingaEditor.Agent.PromptBuffer.prompt_text(new_state.workspace.agent_ui.panel) == ""
    end

    test "preserves the prompt when an attached session rejects locally" do
      for {error, expected_message} <- [
            {:provider_not_ready, "Agent provider still starting"},
            {:credentials_not_configured, "No provider credentials are configured"}
          ] do
        {:ok, session} =
          Session.start_link(
            provider: PromptRejectingProvider,
            provider_opts: [send_prompt_result: {:error, error}, model: "anthropic:test"],
            persist?: false
          )

        on_exit(fn -> Process.exit(session, :kill) end)
        :sys.get_state(session)

        state =
          base_state(session: session)
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

        new_state = AgentCommands.submit_prompt(state)

        assert new_state.shell_runtime.state.notice.message =~ expected_message

        assert MingaEditor.Agent.PromptBuffer.prompt_text(new_state.workspace.agent_ui.panel) ==
                 "draft prompt"
      end
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

      display =
        Transcript.display(messages,
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
                 |> Panel.cache_transcript_display(display, nil)
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
    test "aborts a live turn and restores queued messages to the prompt" do
      session =
        start_supervised!(
          {Session,
           provider: SessionSlowMockProvider, provider_opts: [test_pid: self()], persist?: false}
        )

      assert :ok = Session.subscribe(session)
      assert :ok = Session.send_prompt(session, "active turn")
      assert_receive {:agent_event, ^session, {:status_changed, :thinking}}, 1_000

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

      new_state = AgentCommands.scope_ctrl_c(state)

      assert_receive :provider_abort_called, 1_000
      prompt = MingaEditor.Agent.PromptBuffer.input_text(new_state.workspace.agent_ui.panel)
      assert prompt =~ "steering note"
      assert prompt =~ "follow-up note"
    end

    test "retries the provider when the agent is in error state" do
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

      new_state = AgentCommands.scope_ctrl_c(state)

      assert_receive :restart_provider_called
      assert new_state.shell_runtime.state.notice.message == "Agent provider restarted"
    end
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
      state = base_state()

      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
          state,
          (&UIState.set_thinking_level(&1, "low")).(state.workspace.agent_ui)
        )

      command = command!(:agent_pick_thinking)

      new_state = command.execute.(state)

      assert {:picker, %{picker_ui: picker_ui}} = new_state.shell_runtime.state.modal
      assert picker_ui.source == MingaEditor.UI.Picker.ThinkingLevelSource
      assert picker_ui.context == %{current_level: "low"}
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

  describe "cycle_model/1" do
    test "updates model and thinking level from the session response" do
      {:ok, session} =
        StubServer.start_link(
          cycle_model:
            {:ok,
             %{
               "model" => "openai:o4-mini",
               "index" => 2,
               "total" => 3,
               "thinking_level" => "high"
             }}
        )

      state = base_state(session: session)

      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
          state,
          (&UIState.set_thinking_level(&1, "medium")).(state.workspace.agent_ui)
        )

      new_state = AgentCommands.cycle_model(state)

      assert new_state.workspace.agent_ui.panel.model_name == "openai:o4-mini"
      assert new_state.workspace.agent_ui.panel.thinking_level == "high"
      assert new_state.shell_runtime.state.notice.message == "Model: openai:o4-mini [2/3]"
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
    test "switches from chat to file_viewer" do
      state = base_state(panel_visible: true)

      view = state.workspace.agent_ui.view |> View.activate(nil, nil) |> View.set_focus(:chat)
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
    end

    test "creates an active agent workspace with no file context" do
      state = source_workspace_state()
      source_workspace = TabBar.get_workspace(state.shell_runtime.state.tab_bar, 0)

      new_state = AgentCommands.new_agent_session(state)
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

      new_state = AgentCommands.new_agent_session(state)
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

      new_state = AgentSession.start_agent_session(state)
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

      new_state = AgentSession.start_agent_session(state)
      active_workspace = TabBar.active_workspace(new_state.shell_runtime.state.tab_bar)

      assert MingaEditor.Agent.PromptBuffer.input_text(new_state.workspace.agent_ui.panel) ==
               "active draft"

      assert %WorkspaceAgent{agent_ui: nil, session: session} = active_workspace.payload
      assert is_pid(session)
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

  defp replace_panel(state, transition) do
    MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
      state,
      transition.(state.workspace.agent_ui.panel)
    )
  end
end
