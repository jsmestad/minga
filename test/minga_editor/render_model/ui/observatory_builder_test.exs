defmodule MingaEditor.RenderModel.UI.ObservatoryBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Observatory
  alias Minga.RenderModel.UI.Observatory.Node
  alias Minga.SystemObserver.ProcessSnapshot
  alias Minga.SystemObserver.TreeNode
  alias MingaEditor.Observatory.Data, as: ObservatoryData
  alias MingaEditor.RenderModel.UI.ObservatoryBuilder
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState

  describe "build/1" do
    test "builds hidden observatory when not visible" do
      model = ObservatoryBuilder.build(%{})

      assert %Observatory{} = model
      refute model.visible?
      assert model.nodes == []
    end

    test "builds hidden observatory when Traditional observatory is closed" do
      model = ObservatoryBuilder.build(%TraditionalState{})

      refute model.visible?
    end

    test "builds visible observatory with data" do
      data =
        ObservatoryData.visible(tree_node(), [%{processes: %{self() => %{message_queue_len: 5}}}])

      shell_state =
        %TraditionalState{}
        |> TraditionalState.open_observatory(nil)
        |> TraditionalState.replace_observatory_data(data)

      model = ObservatoryBuilder.build(shell_state)

      assert %Observatory{} = model
      assert model.visible?

      assert [
               %Node{
                 pid: pid,
                 parent_pid: nil,
                 name: ":minga_test",
                 process_class: :worker,
                 depth: 0,
                 memory: 1024,
                 message_queue_len: 1,
                 reductions: 10,
                 sparkline_values: [0.5]
               }
             ] = model.nodes

      assert pid == self()
    end

    test "builds visible observatory with nil data as empty visible" do
      shell_state = TraditionalState.open_observatory(%TraditionalState{}, nil)

      model = ObservatoryBuilder.build(shell_state)

      assert model.visible?
      assert model.nodes == []
    end

    test "uses current function when registered name is nil" do
      model =
        build_visible_node(registered_name: nil, current_function: {Minga.Buffer, :content, 1})

      assert [%Node{name: "Minga.Buffer.content/1"}] = model.nodes
    end

    test "uses unnamed when registered name and current function are nil" do
      model = build_visible_node(registered_name: nil, current_function: nil)

      assert [%Node{name: "unnamed"}] = model.nodes
    end
  end

  defp build_visible_node(opts) do
    data = ObservatoryData.visible(tree_node(opts), [])

    shell_state =
      %TraditionalState{}
      |> TraditionalState.open_observatory(nil)
      |> TraditionalState.replace_observatory_data(data)

    ObservatoryBuilder.build(shell_state)
  end

  defp tree_node(opts \\ []) do
    snapshot = %ProcessSnapshot{
      memory: 1024,
      message_queue_len: 1,
      reductions: 10,
      current_function: Keyword.get(opts, :current_function, {MingaEditor, :loop, 1}),
      registered_name: Keyword.get(opts, :registered_name, :minga_test),
      parent_pid: nil,
      child_type: :worker,
      process_class: :worker
    }

    %TreeNode{pid: self(), snapshot: snapshot, children: [], depth: 0}
  end
end
