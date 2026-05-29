defmodule Minga.RenderModel.UI.ObservatoryTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Observatory
  alias Minga.RenderModel.UI.Observatory.Node

  describe "%Observatory{}" do
    test "defaults to hidden" do
      obs = %Observatory{}

      refute obs.visible?
      assert obs.nodes == []
    end

    test "stores semantic observatory nodes" do
      obs = %Observatory{visible?: true, nodes: [observatory_node()]}

      assert obs.visible?
      assert [%Node{name: ":minga_test", message_queue_len: 1}] = obs.nodes
    end
  end

  defp observatory_node do
    %Node{
      pid: self(),
      parent_pid: nil,
      name: ":minga_test",
      process_class: :worker,
      depth: 0,
      memory: 1024,
      message_queue_len: 1,
      reductions: 10,
      sparkline_values: [0.5]
    }
  end
end
