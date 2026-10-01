defmodule MingaEditor.UI.Picker.AgentModelSourceTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ModelCandidate
  alias MingaAgent.ModelSelection
  alias MingaAgent.ModelSelection.Credential.ApiKey
  alias MingaAgent.Test.ModelPickerSession
  alias MingaAgent.Test.ModelSelectionFixture
  alias MingaAgent.RuntimeState
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

    @spec start_link(String.t()) :: GenServer.on_start()
    def start_link(message), do: GenServer.start_link(__MODULE__, message)

    @impl GenServer
    def init(message), do: {:ok, message}

    @impl GenServer
    def handle_call({:set_model, _selection}, _from, message),
      do: {:reply, {:error, message}, message}
  end

  test "shows exact route, unverified status, favorite, and thinking controls" do
    selection =
      ModelSelectionFixture.selection(
        model_provider: "custom",
        model_id: "private-model",
        display_name: "Private Model",
        base_url: "https://gateway.example/v1",
        transport: "http",
        credential: %ApiKey{provider: "custom", source: :file},
        reasoning: %{effort: "low", options: ["off", "low", "high"]},
        limits: %{context: nil, input: nil, output: nil, request_output: 2_048},
        capabilities: %{tools: :unknown, images: :unknown, streaming: :unknown}
      )

    candidate = %ModelCandidate{selection: selection, favorite: true, current: true}
    session = start_supervised!({ModelPickerSession, [candidate]})

    assert [item] = AgentModelSource.candidates(context(session))
    assert item.id == ModelSelection.id(selection)
    assert item.active
    assert item.annotation == "★ favorite"
    assert item.description =~ "custom via openai_chat"
    assert item.description =~ "https://gateway.example/v1/chat/completions"
    assert item.description =~ "unverified custom route"
    assert item.description =~ "thinking low (off/low/high)"
    assert item.description =~ "tools unknown, images unknown, streaming unknown"
  end

  test "keeps duplicate display names distinct by exact route identity" do
    first =
      ModelSelectionFixture.selection(
        model_id: "shared-name",
        display_name: "Shared Model",
        route_id: "gateway-a/shared-name",
        base_url: "https://gateway-a.example/v1"
      )

    second =
      ModelSelectionFixture.selection(
        model_id: "shared-name",
        display_name: "Shared Model",
        route_id: "gateway-b/shared-name",
        base_url: "https://gateway-b.example/v1"
      )

    candidates = [
      %ModelCandidate{selection: first, favorite: false, current: true},
      %ModelCandidate{selection: second, favorite: false, current: false}
    ]

    session = start_supervised!({ModelPickerSession, candidates})
    items = AgentModelSource.candidates(context(session))

    assert Enum.map(items, & &1.label) == ["Shared Model", "Shared Model"]
    assert items |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 2
    assert Enum.any?(items, &String.contains?(&1.description, "gateway-a.example"))
    assert Enum.any?(items, &String.contains?(&1.description, "gateway-b.example"))
  end

  test "rejected picker selection preserves the prior visible model" do
    selection = ModelSelectionFixture.selection(display_name: "Rejected Model")
    candidate = %ModelCandidate{selection: selection, favorite: false, current: false}
    picker_session = start_supervised!({ModelPickerSession, [candidate]})
    [item] = AgentModelSource.candidates(context(picker_session))

    message = "The exact credential profile is unavailable. Pick another route."
    rejecting_session = start_supervised!({RejectingSession, message})
    state = editor_state(rejecting_session, "Prior Model")

    state = AgentModelSource.on_select(item, state)

    assert state.workspace.agent_ui.panel.model_name == "Prior Model"
    assert state.shell_runtime.state.notice.message == message
  end

  defp editor_state(session, model_name) do
    {tab_bar, workspace} =
      1
      |> Tab.new_agent("Agent")
      |> TabBar.new()
      |> TabBar.add_workspace("Agent", session)

    tab_bar =
      tab_bar
      |> TabBar.move_tab_to_workspace(1, workspace.id)
      |> Map.put(:active_id, 1)

    agent_ui = UIState.new() |> UIState.set_model_name(model_name)

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      workspace: %MingaEditor.Session.State{editing: VimState.new(), agent_ui: agent_ui}
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
  end

  defp context(session) do
    %Context{
      buffers: %Buffers{},
      editing: VimState.new(),
      search: %Search{},
      viewport: Viewport.new(80, 24),
      tab_bar: %{},
      agent_session: session,
      picker_ui: %{},
      capabilities: %{},
      theme: Theme.get!(:doom_one)
    }
  end
end
