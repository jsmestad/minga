defmodule Minga.Frontend.Adapter.GUI.AgentQueueEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.{Caches, EmptyListWire}
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.{Encode, Opcodes}
  alias Minga.RenderModel.UI.Queue

  @opcode Opcodes.gui_agent_queue()

  @spec encode(Queue.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%Queue{} = queue, %Caches{last_agent_queue: queue} = caches), do: {nil, caches}

  def encode(%Queue{} = queue, %Caches{} = caches),
    do: {encode_command(queue), %{caches | last_agent_queue: queue}}

  @spec encode_command(Queue.t()) :: binary()
  def encode_command(%Queue{} = queue) do
    payload = queue |> to_wire() |> Encode.encode_gui_agent_queue() |> IO.iodata_to_binary()

    :gui_agent_queue
    |> Writer.new()
    |> Writer.uint8(:opcode, @opcode)
    |> Writer.payload32(:payload, payload)
    |> Writer.finish()
  end

  @spec to_wire(Queue.t()) :: map()
  defp to_wire(%Queue{visible?: false}), do: %{visible: 0}

  defp to_wire(%Queue{} = queue) do
    %{
      visible: 1,
      focused: if(queue.focused?, do: 1, else: 0),
      workspace_id: queue.workspace_id,
      record_id: queue.record_id,
      title: queue.title,
      summary: queue.summary,
      removed_note: queue.removed_note,
      selected_id: queue.selected_id || 0,
      hints:
        Enum.map(queue.hints, fn {key, label, action} ->
          %{key: key, label: label, action: action}
        end),
      pending: Enum.map(queue.pending, &row/1),
      removed: Enum.map(queue.removed, &row/1),
      empty: EmptyListWire.to_wire(queue.empty)
    }
  end

  @spec row(Queue.row()) :: map()
  defp row(%{kind: :steering} = row), do: %{row | kind: 0}
  defp row(%{kind: :follow_up} = row), do: %{row | kind: 1}
end
