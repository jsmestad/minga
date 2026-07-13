defmodule MingaEditor.RenderModel.UI.ObservatoryBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.Observatory
  alias Minga.RenderModel.UI.Observatory.Node
  alias Minga.SystemObserver.TreeNode
  alias MingaEditor.Observatory.Data, as: ObservatoryData
  alias MingaEditor.Shell.Traditional.Observatory, as: ObservatoryState
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState

  @spec build(term()) :: Observatory.t()
  def build(%TraditionalState{} = shell_state) do
    observatory = TraditionalState.observatory(shell_state)
    build_observatory(ObservatoryState.visible?(observatory), ObservatoryState.data(observatory))
  end

  def build(_shell_state), do: %Observatory{}

  @spec build_observatory(boolean(), ObservatoryData.t() | nil) :: Observatory.t()
  defp build_observatory(true, %ObservatoryData{} = data), do: observatory_model(data)
  defp build_observatory(true, nil), do: observatory_model(ObservatoryData.visible(nil, []))
  defp build_observatory(false, _data), do: %Observatory{}

  @spec observatory_model(ObservatoryData.t()) :: Observatory.t()
  defp observatory_model(%ObservatoryData{visible: false}), do: %Observatory{}

  defp observatory_model(%ObservatoryData{} = data) do
    nodes =
      data.tree
      |> TreeNode.flatten()
      |> Enum.map(&node_model(&1, data.samples))

    %Observatory{visible?: true, nodes: nodes}
  end

  @spec node_model(TreeNode.t(), [Minga.SystemObserver.process_tree_snapshot()]) :: Node.t()
  defp node_model(%TreeNode{} = tree_node, samples) do
    snapshot = tree_node.snapshot

    %Node{
      pid: tree_node.pid,
      parent_pid: snapshot.parent_pid,
      name: observatory_name(snapshot),
      process_class: snapshot.process_class,
      depth: tree_node.depth,
      memory: snapshot.memory,
      message_queue_len: snapshot.message_queue_len,
      reductions: snapshot.reductions,
      sparkline_values: sparkline_values(samples, tree_node.pid)
    }
  end

  @spec sparkline_values([Minga.SystemObserver.process_tree_snapshot()], pid()) :: [float()]
  defp sparkline_values(samples, pid) do
    samples
    |> Enum.take(-30)
    |> Enum.map(&observatory_sample_value(&1, pid))
  end

  @spec observatory_sample_value(Minga.SystemObserver.process_tree_snapshot(), pid()) :: float()
  defp observatory_sample_value(%{processes: processes}, pid) do
    case Map.get(processes, pid) do
      %{message_queue_len: len} when len > 0 -> min(len / 10.0, 1.0)
      _ -> 0.0
    end
  end

  @spec observatory_name(Minga.SystemObserver.ProcessSnapshot.t()) :: String.t()
  defp observatory_name(%{registered_name: name}) when is_atom(name) and not is_nil(name) do
    inspect(name)
  end

  defp observatory_name(%{current_function: {module, function, arity}}) do
    "#{inspect(module)}.#{function}/#{arity}"
  end

  defp observatory_name(_snapshot), do: "unnamed"
end
