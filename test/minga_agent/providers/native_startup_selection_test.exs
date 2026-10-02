defmodule MingaAgent.Providers.NativeStartupSelectionTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ModelSelection
  alias MingaAgent.Providers.Native
  alias MingaAgent.Test.ModelSelectionFixture

  @tag :tmp_dir
  test "an exact selection preserves its reasoning policy", %{tmp_dir: root} do
    selection =
      ModelSelectionFixture.selection(
        reasoning: %{effort: "default", options: ["default", "low"]}
      )

    pid =
      start_supervised!(
        {Native,
         subscriber: self(),
         model_selection: selection,
         project_root: root,
         tools: [],
         skip_api_key_env: true}
      )

    assert {:ok, %{model_selection: ^selection, thinking_level: "default"}} =
             Native.get_state(pid)
  end

  test "an exact selection rejects a second reasoning policy" do
    assert {:error, reason} =
             start_supervised(
               {Native,
                subscriber: self(),
                model_selection: ModelSelectionFixture.selection(),
                thinking_level: "low"}
             )

    assert inspect(reason) =~ "Pass reasoning policy in model_selection"
  end

  @tag :tmp_dir
  test "model startup keeps the resolver default or validates an explicit override", %{
    tmp_dir: root
  } do
    for effort <- [nil, "low"] do
      pid =
        start_supervised!(
          Supervisor.child_spec(
            {Native,
             subscriber: self(),
             model: ModelSelectionFixture.model_intent(),
             thinking_level: effort,
             model_resolver_opts: ModelSelectionFixture.resolver_opts(),
             project_root: root,
             tools: [],
             skip_api_key_env: true},
            id: {:legacy, effort}
          )
        )

      {:ok, state} = Native.get_state(pid)
      assert state.thinking_level == (effort || "default")
      assert %ModelSelection{} = state.model_selection
    end

    assert {:error, reason} =
             start_supervised(
               Supervisor.child_spec(
                 {Native,
                  subscriber: self(),
                  model: ModelSelectionFixture.model_intent(),
                  thinking_level: "unsupported",
                  model_resolver_opts: ModelSelectionFixture.resolver_opts()},
                 id: :invalid
               )
             )

    assert inspect(reason) =~ "unsupported"
  end
end
