defmodule Minga.Frontend.Adapter.GUI.ObservatoryEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.ObservatoryEncoder
  alias Minga.RenderModel.UI.Observatory
  alias Minga.RenderModel.UI.Observatory.Node
  alias Minga.SystemObserver.ProcessSnapshot
  alias Minga.SystemObserver.TreeNode
  alias MingaEditor.Frontend.Protocol.GUI, as: ProtocolGUI
  alias MingaEditor.Observatory.Data, as: ObservatoryData

  @op_gui_observatory Minga.Protocol.Opcodes.gui_observatory()

  describe "encode/2" do
    test "encodes hidden observatory" do
      model = %Observatory{}
      caches = Caches.new()

      {cmd, _caches} = ObservatoryEncoder.encode(model, caches)

      assert <<@op_gui_observatory, _payload_len::32, _payload::binary>> = cmd
    end

    test "encodes visible observatory" do
      model = %Observatory{visible?: true, nodes: [observatory_node()]}
      caches = Caches.new()

      {cmd, _caches} = ObservatoryEncoder.encode(model, caches)

      assert <<@op_gui_observatory, _payload_len::32, _payload::binary>> = cmd
    end

    test "returns nil on second call with same fingerprint" do
      model = %Observatory{}
      caches = Caches.new()

      {cmd1, caches} = ObservatoryEncoder.encode(model, caches)
      assert cmd1 != nil

      {cmd2, _caches} = ObservatoryEncoder.encode(model, caches)
      assert cmd2 == nil
    end

    test "re-encodes when semantic fields change" do
      model1 = %Observatory{}
      model2 = %Observatory{visible?: true, nodes: []}

      caches = Caches.new()
      {_, caches} = ObservatoryEncoder.encode(model1, caches)
      {cmd2, _caches} = ObservatoryEncoder.encode(model2, caches)

      assert cmd2 != nil
      assert cmd2 == ObservatoryEncoder.encode_command(model2)
    end

    test "transitions from visible to hidden" do
      visible_model = %Observatory{visible?: true, nodes: []}
      hidden_model = %Observatory{}

      caches = Caches.new()
      {_, caches} = ObservatoryEncoder.encode(visible_model, caches)
      {cmd, _caches} = ObservatoryEncoder.encode(hidden_model, caches)

      assert cmd == ObservatoryEncoder.encode_command(hidden_model)
    end

    test "produces byte-identical output to legacy ProtocolGUI for hidden state" do
      assert ObservatoryEncoder.encode_command(%Observatory{}) ==
               ProtocolGUI.encode_gui_observatory(ObservatoryData.hidden())
    end

    test "produces byte-identical output to legacy ProtocolGUI for empty visible state" do
      model = %Observatory{visible?: true, nodes: []}
      legacy = ObservatoryData.visible(nil, [])

      assert ObservatoryEncoder.encode_command(model) ==
               ProtocolGUI.encode_gui_observatory(legacy)
    end

    test "produces byte-identical output to legacy ProtocolGUI for visible tree with samples" do
      tree = tree_node()
      samples = [%{processes: %{self() => %{message_queue_len: 5}}}]
      model = %Observatory{visible?: true, nodes: [observatory_node()]}
      legacy = ObservatoryData.visible(tree, samples)

      assert ObservatoryEncoder.encode_command(model) ==
               ProtocolGUI.encode_gui_observatory(legacy)
    end

    test "produces byte-identical output for chunked sections and clamped samples" do
      samples = [
        %{processes: %{self() => %{message_queue_len: 25}}},
        %{processes: %{self() => %{message_queue_len: 0}}}
      ]

      tree =
        tree_node(
          children: Enum.map(1..1700, fn _index -> tree_node(depth: 1, parent_pid: self()) end)
        )

      model = %Observatory{
        visible?: true,
        nodes: Enum.map(TreeNode.flatten(tree), &node_from_tree(&1, samples))
      }

      legacy = ObservatoryData.visible(tree, samples)

      assert ObservatoryEncoder.encode_command(model) ==
               ProtocolGUI.encode_gui_observatory(legacy)
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

  defp tree_node(opts \\ []) do
    snapshot = %ProcessSnapshot{
      memory: Keyword.get(opts, :memory, 1024),
      message_queue_len: Keyword.get(opts, :message_queue_len, 1),
      reductions: Keyword.get(opts, :reductions, 10),
      current_function: {MingaEditor, :loop, 1},
      registered_name: :minga_test,
      parent_pid: Keyword.get(opts, :parent_pid),
      child_type: :worker,
      process_class: :worker
    }

    %TreeNode{
      pid: self(),
      snapshot: snapshot,
      children: Keyword.get(opts, :children, []),
      depth: Keyword.get(opts, :depth, 0)
    }
  end

  defp node_from_tree(%TreeNode{} = node, samples) do
    snapshot = node.snapshot

    %Node{
      pid: node.pid,
      parent_pid: snapshot.parent_pid,
      name: snapshot.registered_name |> inspect(),
      process_class: snapshot.process_class,
      depth: node.depth,
      memory: snapshot.memory,
      message_queue_len: snapshot.message_queue_len,
      reductions: snapshot.reductions,
      sparkline_values: sparkline_values(samples, node.pid)
    }
  end

  defp sparkline_values(samples, pid) do
    samples
    |> Enum.take(-30)
    |> Enum.map(fn %{processes: processes} ->
      case Map.get(processes, pid) do
        %{message_queue_len: len} when len > 0 -> min(len / 10.0, 1.0)
        _ -> 0.0
      end
    end)
  end
end
