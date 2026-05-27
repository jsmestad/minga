defmodule Minga.RenderModel.UI.AgentContextTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.AgentContext

  describe "%AgentContext{}" do
    test "requires visible" do
      ac = %AgentContext{visible: false}

      assert ac.visible == false
      assert ac.task == ""
      assert ac.status == :idle
      assert ac.can_approve == false
    end

    test "accepts all fields" do
      ts = DateTime.utc_now()

      ac = %AgentContext{
        visible: true,
        task: "Fix the build",
        dispatch_timestamp: ts,
        status: :working,
        can_approve: false
      }

      assert ac.visible == true
      assert ac.task == "Fix the build"
      assert ac.dispatch_timestamp == ts
      assert ac.status == :working
      assert ac.can_approve == false
    end

    test "can_approve is true for approvable statuses" do
      ts = DateTime.utc_now()

      ac = %AgentContext{
        visible: true,
        task: "Done task",
        dispatch_timestamp: ts,
        status: :done,
        can_approve: true
      }

      assert ac.can_approve == true
    end
  end
end
