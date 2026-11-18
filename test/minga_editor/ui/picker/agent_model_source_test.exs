defmodule MingaEditor.UI.Picker.AgentModelSourceTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.ModelCandidate
  alias MingaAgent.ModelSelection
  alias MingaAgent.ModelSelection.Credential.OAuth
  alias MingaAgent.Providers.Native
  alias MingaAgent.Session
  alias MingaAgent.Test.ModelPickerSession
  alias MingaAgent.Test.ModelSelectionFixture
  alias MingaAgent.RuntimeState
  alias MingaEditor.PickerUI
  alias MingaEditor.Agent.UIState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Search
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.UI.Picker.AgentModelSource
  alias MingaEditor.UI.Picker.Candidate
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

    assert [item] = AgentModelSource.candidates(context(session))
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

  defp start_codex_session(plug) do
    credential = OAuth.new("picker-account", "/tmp/model-picker-oauth.json")
    snapshot = Snapshot.new(%{"openai" => :env}, credential)

    oauth = fn :openai_codex, oauth_file: path ->
      {:ok,
       %{
         provider_key: "openai-codex",
         account_id: credential.account_id,
         oauth_file: path,
         token: "picker-token"
       }}
    end

    start_supervised!(
      {Session,
       provider: Native,
       credentials_snapshot_fn: fn -> snapshot end,
       model: "openai:no-such-model",
       persist?: false,
       provider_opts: [
         model_resolver_opts: ModelSelectionFixture.resolver_opts(),
         credential_opts: [
           oauth_resolver: oauth,
           plug: plug
         ]
       ]}
    )
  end

  test "Codex discovery failure keeps API-key choices and shows a login notice" do
    session = start_codex_session(fn conn -> Plug.Conn.send_resp(conn, 401, "") end)

    assert {:ok, [item], %{status: status} = meta} =
             AgentModelSource.async_fetch(context(session))

    assert item.meta.selection.route.request_provider == :openai
    assert status =~ "/login"
    assert {:ok, [candidate]} = Session.get_available_models(session)
    assert candidate.selection.route.request_provider == :openai

    Session.refresh_credentials(session)
    assert {:ok, _} = Session.get_available_models(session)

    {opened, revision} =
      PickerUI.open_loading(editor_state(session, "Prior Model"), AgentModelSource)

    assert {:ok, published} =
             PickerUI.apply_fetch_result(
               opened,
               AgentModelSource,
               revision,
               {:ok, [item], Candidate.from_items([item]), meta}
             )

    assert {:picker, %{picker_ui: %{picker: %{items: [^item]}}}} =
             published.shell_runtime.state.modal

    assert published.shell_runtime.state.notice == opened.shell_runtime.state.notice
  end

  test "canceling a refresh preserves the completed inventory until a new result replaces it" do
    owner = self()
    calls = :atomics.new(1, [])

    session =
      start_codex_session(fn conn ->
        case :atomics.add_get(calls, 1, 1) do
          1 ->
            Req.Test.json(conn, %{"models" => [%{"slug" => "test-model", "visibility" => "list"}]})

          2 ->
            send(owner, {:refresh_started, self()})

            receive do
              :finish -> Plug.Conn.send_resp(conn, 401, "")
            end

          3 ->
            Plug.Conn.send_resp(conn, 401, "")
        end
      end)

    assert {:ok, ready, meta} = AgentModelSource.async_fetch(context(session))

    assert Enum.sort(Enum.map(ready, & &1.meta.selection.route.request_provider)) == [
             :openai,
             :openai_codex
           ]

    worker = spawn(fn -> AgentModelSource.async_fetch(context(session)) end)
    monitor = Process.monitor(worker)
    assert_receive {:refresh_started, ^worker}, 1_000
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}

    assert {:ok, candidates} = Session.get_available_models(session)
    assert Enum.any?(candidates, &(&1.selection.route.request_provider == :openai_codex))

    assert {:ok, [_], %{status: _}} = AgentModelSource.async_fetch(context(session))
    assert {:ok, [candidate]} = Session.get_available_models(session)
    assert candidate.selection.route.request_provider == :openai

    assert {:ok, [item], [_], empty_meta} =
             AgentModelSource.for_publication(
               {:ok, ready, Candidate.from_items(ready), meta},
               session
             )

    assert item.meta.selection.route.request_provider == :openai
    assert empty_meta == %{}
  end

  test "credential refresh during discovery keeps API-key choices without a stale login notice" do
    owner = self()

    session =
      start_codex_session(fn conn ->
        send(owner, {:discovery_started, self()})

        receive do
          :reply -> Plug.Conn.send_resp(conn, 401, "")
        end
      end)

    worker = Task.async(fn -> AgentModelSource.async_fetch(context(session)) end)
    assert_receive {:discovery_started, pid}, 1_000
    Session.refresh_credentials(session)
    assert {:ok, [_]} = Session.get_available_models(session)
    send(pid, :reply)

    assert {:ok, [item], meta} = Task.await(worker)
    assert item.meta.selection.route.request_provider == :openai
    assert meta == %{}
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
    items = AgentModelSource.candidates(context(session))

    assert Enum.map(items, & &1.label) == ["Shared Model", "Shared Model"]
    assert items |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 2
    assert Enum.all?(items, &String.contains?(&1.description, "api.openai.example"))
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
