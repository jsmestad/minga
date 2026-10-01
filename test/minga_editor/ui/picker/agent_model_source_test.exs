defmodule MingaEditor.UI.Picker.AgentModelSourceTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ModelCandidate
  alias MingaAgent.ModelSelection
  alias MingaAgent.ModelSelection.Credential.ApiKey
  alias MingaAgent.Test.ModelPickerSession
  alias MingaAgent.Test.ModelSelectionFixture
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Search
  alias MingaEditor.UI.Picker.AgentModelSource
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Theme
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

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
