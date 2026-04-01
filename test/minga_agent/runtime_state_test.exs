defmodule MingaAgent.RuntimeStateTest do
  use ExUnit.Case, async: true

  alias MingaAgent.RuntimeState

  describe "set_status/2" do
    test "updates the status field" do
      rt = %RuntimeState{} |> RuntimeState.set_status(:thinking)
      assert rt.status == :thinking
    end

    test "transitions through lifecycle states" do
      rt =
        %RuntimeState{}
        |> RuntimeState.set_status(:idle)
        |> RuntimeState.set_status(:thinking)
        |> RuntimeState.set_status(:tool_executing)
        |> RuntimeState.set_status(:idle)

      assert rt.status == :idle
    end
  end

  describe "busy?/1" do
    test "true for :thinking" do
      assert RuntimeState.busy?(%RuntimeState{status: :thinking})
    end

    test "true for :tool_executing" do
      assert RuntimeState.busy?(%RuntimeState{status: :tool_executing})
    end

    test "false for :idle" do
      refute RuntimeState.busy?(%RuntimeState{status: :idle})
    end

    test "false for :error" do
      refute RuntimeState.busy?(%RuntimeState{status: :error})
    end

    test "false for nil" do
      refute RuntimeState.busy?(%RuntimeState{})
    end
  end

  describe "identity setters" do
    test "set_session_id/2" do
      rt = %RuntimeState{} |> RuntimeState.set_session_id("abc-123")
      assert rt.active_session_id == "abc-123"
    end

    test "set_model/2" do
      rt = %RuntimeState{} |> RuntimeState.set_model("claude-4-sonnet")
      assert rt.model_name == "claude-4-sonnet"
    end

    test "set_provider/2" do
      rt = %RuntimeState{} |> RuntimeState.set_provider("anthropic")
      assert rt.provider_name == "anthropic"
    end

    test "set_session_id/2 clears with nil" do
      rt =
        %RuntimeState{active_session_id: "old"}
        |> RuntimeState.set_session_id(nil)

      assert rt.active_session_id == nil
    end
  end
end
