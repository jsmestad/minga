defmodule MingaEditor.Agent.SessionProjectionTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Test.ModelSelectionFixture
  alias MingaEditor.Agent.Events
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.RenderPipeline.TestHelpers

  test "initial hydration projects resolved policy without an activation notice, including pending local routes" do
    selections = [
      {:configured,
       ModelSelectionFixture.selection(
         display_name: "Cloud model",
         reasoning: %{effort: "default", options: ["default", "low"]}
       )},
      {:checking,
       ModelSelectionFixture.selection(
         base_url: "http://127.0.0.1:11434/v1",
         model_provider: "ollama",
         display_name: "Local model",
         reasoning: %{effort: "low", options: ["low", "high"]}
       )}
    ]

    for {readiness, selection} <- selections do
      state = TestHelpers.base_state(rendering: :disabled)

      snapshot = %{
        status: :idle,
        pending_approval: nil,
        error: nil,
        active_tool_name: nil,
        credentials_configured: readiness == :configured,
        credential_readiness: readiness,
        model_selection: selection
      }

      projected = AgentLifecycle.apply_session_snapshot(state, snapshot)
      panel = projected.workspace.agent_ui.panel
      assert panel.model_name == selection.route.display_name
      assert panel.provider_name == selection.route.model_provider
      assert panel.thinking_level == selection.policy.reasoning.effort
      assert panel.credential_readiness == readiness
      assert projected.workspace.agent_ui.view.toast == state.workspace.agent_ui.view.toast

      assert AgentLifecycle.apply_session_snapshot(projected, snapshot).workspace.agent_ui ==
               projected.workspace.agent_ui
    end
  end

  test "absence of a selection preserves the existing model while confirmed readiness is projected" do
    state = TestHelpers.base_state(rendering: :disabled)

    snapshot = %{
      status: :idle,
      pending_approval: nil,
      error: nil,
      credentials_configured: false,
      credential_readiness: :unconfigured,
      model_selection: nil
    }

    projected = AgentLifecycle.apply_session_snapshot(state, snapshot)

    assert projected.workspace.agent_ui.panel.model_name ==
             state.workspace.agent_ui.panel.model_name

    assert projected.workspace.agent_ui.panel.credential_readiness == :unconfigured
    assert projected.workspace.agent_ui.view.toast == state.workspace.agent_ui.view.toast
  end

  test "an actual activation event still projects the policy and adds its notice" do
    state = TestHelpers.base_state(rendering: :disabled)
    selection = ModelSelectionFixture.selection(display_name: "Activated model")
    projected = Events.dispatch(state, {:model_selection_changed, selection})
    assert projected.workspace.agent_ui.panel.model_name == "Activated model"
    assert projected.workspace.agent_ui.view.toast != state.workspace.agent_ui.view.toast
  end
end
