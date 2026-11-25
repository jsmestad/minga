defmodule MingaEditor.Commands.AgentSessionModelTest do
  @moduledoc """
  A task started beside a conversation runs on that conversation's model: `start_agent_session/2` with `:model` starts the new workspace's session on the selection's exact route, and without it the workspace keeps the configured default.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaAgent.ModelSelection
  alias MingaAgent.Providers.RecordingProvider
  alias MingaAgent.Session.ConnectionSnapshot
  alias MingaAgent.Session.ConnectionTarget
  alias MingaAgent.Session.ProviderLifecycle
  alias MingaAgent.Test.ModelSelectionFixture
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentConnection
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Frontend
  alias MingaEditor.State.Interaction
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.State.Workspace.Agent, as: WorkspaceAgent
  alias MingaEditor.VimState
  alias MingaEditor.Window

  test "the conversation's model selection is what a task started beside it runs on" do
    selection = ModelSelectionFixture.selection()
    ui = %UIState{connection: snapshot(selection)}

    assert UIState.model_selection(ui) == selection
    assert UIState.model_selection(%UIState{}) == nil

    panel = UIState.start_on_model(ui, selection).panel
    assert panel.model_name == ModelSelection.id(selection)
    assert panel.provider_name == selection.route.model_provider
    assert panel.thinking_level == selection.policy.reasoning.effort
    assert Panel.ensure_configured_model(panel).model_name == ModelSelection.id(selection)
  end

  test "a background start with :model starts its workspace on that route" do
    selection = ModelSelectionFixture.selection()

    state =
      AgentSession.start_agent_session(editor_state(),
        background: true,
        session_start_hook_enabled?: false,
        recover_interrupted_work?: false,
        model: selection
      )

    assert background_panel(state).model_name == ModelSelection.id(selection)
    stop_started(state)
  end

  test "SPC a n's New task runs on the model of the conversation in front, like c" do
    selection = ModelSelectionFixture.selection()
    state = editor_state()

    state = %{
      state
      | workspace: %{
          state.workspace
          | agent_ui: %{state.workspace.agent_ui | connection: snapshot(selection)}
        }
    }

    prompted = MingaEditor.Commands.execute(state, :agent_new_task)

    assert {:prompt, %{prompt_ui: %{handler: MingaEditor.UI.Prompt.NewTask}}} =
             prompted.shell_runtime.state.modal

    started = MingaEditor.UI.Prompt.NewTask.on_submit("Add tests", prompted)

    assert background_panel(started).model_name == ModelSelection.id(selection)
    stop_started(started)
  end

  test "a background start without :model keeps the configured default" do
    state =
      AgentSession.start_agent_session(editor_state(),
        background: true,
        session_start_hook_enabled?: false,
        recover_interrupted_work?: false
      )

    refute String.starts_with?(background_panel(state).model_name, "ms2_")
    stop_started(state)
  end

  @spec snapshot(ModelSelection.t()) :: ConnectionSnapshot.t()
  defp snapshot(selection) do
    provider =
      ProviderLifecycle.new(
        module: Minga.Test.StubProvider,
        id: "test",
        source: :builtin,
        provider_opts: [],
        model_name: "model",
        provider_name: "test",
        restart: []
      )

    target = ConnectionTarget.new(self(), "session", nil, make_ref())
    ConnectionSnapshot.new(target, :configured, selection, provider, :idle, nil)
  end

  @spec background_panel(EditorState.t()) :: Panel.t()
  defp background_panel(state) do
    assert [%{payload: %WorkspaceAgent{agent_ui: %UIState{panel: panel}}}] =
             Enum.filter(state.shell_runtime.state.tab_bar.workspaces, &(&1.kind == :agent))

    panel
  end

  @spec stop_started(EditorState.t()) :: :ok
  defp stop_started(state) do
    state = Minga.Test.AgentSessionStart.settle(state)

    for %{kind: :agent, payload: %WorkspaceAgent{session: session}} <-
          state.shell_runtime.state.tab_bar.workspaces,
        is_pid(session) do
      MingaAgent.SessionManager.stop_session_by_pid(session)
    end

    :ok
  end

  @spec editor_state() :: EditorState.t()
  defp editor_state do
    buf = start_supervised!({BufferProcess, content: "hello\n"})
    prompt = start_supervised!({BufferProcess, content: ""}, id: :prompt)

    %EditorState{
      frontend: %Frontend{port_manager: nil},
      agent_connection: AgentConnection.new(RecordingProvider, test_pid: self()),
      workspace: %MingaEditor.Session.State{
        editing: VimState.new(),
        buffers: %Buffers{active: buf, list: [buf], active_index: 0},
        windows: %Windows{
          tree: {:leaf, 1},
          map: %{1 => Window.new(1, buf, 24, 80)},
          active: 1,
          next_id: 2
        },
        agent_ui: %UIState{panel: %Panel{prompt_buffer: prompt}}
      },
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          TraditionalState.install_tab_bar(
            %TraditionalState{},
            TabBar.new(Tab.new_file(1, "scratch"))
          )
        ),
      interaction: %Interaction{}
    }
  end
end
