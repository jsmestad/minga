defmodule MingaEditor.UI.Picker.AgentModelSourceTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ModelCandidate
  alias MingaAgent.ModelSelection
  alias MingaAgent.Test.ModelPickerSession
  alias MingaAgent.Test.ModelSelectionFixture
  alias MingaAgent.RuntimeState
  alias MingaAgent.Session.{ConnectionSnapshot, ConnectionTarget}
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Agent.UIState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Search
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.UI.Picker.AgentModelSource
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Theme
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

  defmodule RejectingSession do
    use GenServer

    @spec start_link({[ModelCandidate.t()], String.t()}) :: GenServer.on_start()
    def start_link(fixture), do: GenServer.start_link(__MODULE__, fixture)

    @impl GenServer
    def init(message), do: {:ok, message}

    @impl GenServer
    def handle_call(:get_available_models, _from, {candidates, _message} = fixture),
      do: {:reply, {:ok, candidates}, fixture}

    def handle_call(
          {:set_model_for_target, %ConnectionTarget{session: session}, _selection},
          _from,
          {_candidates, message} = fixture
        )
        when session == self(), do: {:reply, {:error, message}, fixture}
  end

  test "shows exact route, unverified status, favorite, and thinking controls" do
    selection =
      ModelSelectionFixture.selection(
        model_provider: "openai",
        model_id: "gpt-4",
        display_name: "GPT-4",
        base_url: "https://api.openai.com/v1",
        transport: "http",
        reasoning: %{effort: "low", options: ["off", "low", "high"]},
        limits: %{context: 128_000, input: nil, output: 8_192, request_output: 2_048},
        capabilities: %{tools: true, images: true, streaming: true}
      )

    candidate = %ModelCandidate{selection: selection, favorite: true, current: true}
    session = start_supervised!({ModelPickerSession, [candidate]})

    assert [item] = model_items(context(connection(session), 1))
    assert item.id == ModelSelection.id(selection)
    assert item.active
    assert item.annotation == "★ favorite"
    assert item.description =~ "openai via openai_chat"
    assert item.description =~ "https://api.openai.com/v1/chat/completions"
    assert item.description =~ "unverified catalog route"
    assert item.description =~ "openai:env"
    assert item.description =~ "thinking low (off/low/high)"
    assert item.description =~ "tools yes, images yes, streaming yes"
  end

  test "keeps duplicate display names distinct by exact route identity" do
    first =
      ModelSelectionFixture.selection(
        model_id: "shared-name",
        display_name: "Shared Model",
        route_id: "openai/shared-name"
      )

    second =
      ModelSelectionFixture.selection(
        model_id: "shared-name-v2",
        display_name: "Shared Model",
        route_id: "openai/shared-name-v2"
      )

    candidates = [
      %ModelCandidate{selection: first, favorite: false, current: true},
      %ModelCandidate{selection: second, favorite: false, current: false}
    ]

    session = start_supervised!({ModelPickerSession, candidates})
    items = model_items(context(connection(session), 1))

    assert Enum.map(items, & &1.label) == ["Shared Model", "Shared Model"]
    assert items |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 2
    assert Enum.all?(items, &String.contains?(&1.description, "api.openai.example"))
  end

  test "rejected picker selection preserves the prior visible model" do
    selection = ModelSelectionFixture.selection(display_name: "Rejected Model")
    candidate = %ModelCandidate{selection: selection, favorite: false, current: false}
    message = "The exact credential profile is unavailable. Pick another route."
    session = start_supervised!({RejectingSession, {[candidate], message}})
    task_supervisor = start_supervised!({Task.Supervisor, []})
    scheduler = start_supervised!({EffectScheduler, task_supervisor: task_supervisor})
    :ok = EffectScheduler.attach(scheduler, self())
    connection = connection(session)
    {state, workspace_id} = editor_state(connection, "Prior Model", scheduler)
    [item] = model_items(context(connection, workspace_id))

    state = AgentModelSource.on_select(item, state)
    assert_receive {:effect_result, ^scheduler, %Outcome{} = outcome}, 1_000

    assert {:noreply, state} =
             MingaEditor.handle_info({:effect_result, scheduler, outcome}, state)

    assert state.workspace.agent_ui.panel.model_name == "Prior Model"
    assert state.shell_runtime.state.notice.message == message
  end

  test "a delayed save for the same durable ID cannot notify a replacement conversation" do
    session = start_supervised!({ModelPickerSession, []})
    committed = connection(session)
    {state, id} = editor_state(committed, "Active Model", nil)
    saved = {:agent_event, session, {:connection_api_key_saved, id, committed.target, make_ref()}}

    assert {:noreply, notified} = MingaEditor.handle_info(saved, state)
    assert notified.shell_runtime.state.notice.message == "API key saved."

    replacement = connection(session)
    assert replacement.target.session_id == committed.target.session_id
    {replaced, ^id} = editor_state(replacement, "Restored Model", nil)

    assert {:noreply, ignored} = MingaEditor.handle_info(saved, replaced)
    refute ignored.shell_runtime.state.notice.message
  end

  defp editor_state(
         %ConnectionSnapshot{target: %{session: session}} = connection,
         model_name,
         scheduler
       ) do
    {tab_bar, workspace} =
      1
      |> Tab.new_agent("Agent")
      |> TabBar.new()
      |> TabBar.add_workspace("Agent", session)

    tab_bar =
      tab_bar
      |> TabBar.move_tab_to_workspace(1, workspace.id)
      |> Map.put(:active_id, 1)

    agent_ui =
      UIState.new()
      |> UIState.project_connection(connection)
      |> UIState.set_model_name(model_name)

    state =
      %EditorState{
        frontend: %MingaEditor.State.Frontend{port_manager: nil, rendering: :disabled},
        workspace: %MingaEditor.Session.State{editing: VimState.new(), agent_ui: agent_ui},
        effect_scheduler: scheduler
      }
      |> then(fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            tab_bar
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)
      |> MingaEditor.Shell.Traditional.Workflow.install_agent_state(%AgentState{
        runtime: %RuntimeState{status: :idle},
        error: nil,
        spinner_timer: nil
      })

    {state, workspace.id}
  end

  defp context(%ConnectionSnapshot{target: %{session: session} = target} = snapshot, workspace_id) do
    %Context{
      buffers: %Buffers{},
      editing: VimState.new(),
      search: %Search{},
      viewport: Viewport.new(80, 24),
      tab_bar: %{},
      agent_session: session,
      picker_ui: %{
        context: %{
          target: target,
          connection: snapshot,
          workspace_id: workspace_id,
          connection_prompt: nil
        }
      },
      capabilities: %{},
      theme: Theme.get!(:doom_one)
    }
  end

  defp model_items(context) do
    Enum.filter(
      AgentModelSource.candidates(context),
      &match?({:model, %ModelSelection{}}, &1.meta.intent)
    )
  end

  defp connection(session) do
    %ConnectionSnapshot{
      target: ConnectionTarget.new(session, "fixture-conversation", nil, make_ref()),
      credential_readiness: :configured,
      provider_phase: :running,
      model_selection: nil,
      operation: :idle,
      problem: nil
    }
  end
end
