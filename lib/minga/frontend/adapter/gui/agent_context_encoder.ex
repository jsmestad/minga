defmodule Minga.Frontend.Adapter.GUI.AgentContextEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.AgentContext

  @op_gui_agent_context Opcodes.gui_agent_context()

  @spec encode(AgentContext.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%AgentContext{visible: false} = model, %Caches{} = caches) do
    fp = :erlang.phash2(model)

    if fp != caches.last_agent_context_fp do
      cmd = encode_agent_context_binary(model)
      {cmd, %{caches | last_agent_context_fp: fp}}
    else
      {nil, caches}
    end
  end

  def encode(%AgentContext{} = model, %Caches{} = caches) do
    fp = :erlang.phash2(model)

    if fp != caches.last_agent_context_fp do
      cmd = encode_agent_context_binary(model)
      {cmd, %{caches | last_agent_context_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_agent_context_binary(AgentContext.t()) :: binary()
  defp encode_agent_context_binary(%AgentContext{visible: false}) do
    # Hidden: visible=0, empty task, current timestamp, idle status, can_approve=0
    timestamp_seconds = DateTime.to_unix(DateTime.utc_now())
    task_bytes = ""

    IO.iodata_to_binary([
      @op_gui_agent_context,
      <<0::8, byte_size(task_bytes)::16, task_bytes::binary, timestamp_seconds::64, 0::8, 0::8>>
    ])
  end

  defp encode_agent_context_binary(%AgentContext{} = model) do
    visible_byte = 1
    task_bytes = :erlang.iolist_to_binary([model.task])
    timestamp_seconds = DateTime.to_unix(model.dispatch_timestamp)
    status_byte = status_to_byte(model.status)
    can_approve_byte = if model.can_approve, do: 1, else: 0

    IO.iodata_to_binary([
      @op_gui_agent_context,
      <<visible_byte::8, byte_size(task_bytes)::16, task_bytes::binary, timestamp_seconds::64,
        status_byte::8, can_approve_byte::8>>
    ])
  end

  @spec status_to_byte(AgentContext.status()) :: non_neg_integer()
  defp status_to_byte(:idle), do: 0
  defp status_to_byte(:working), do: 1
  defp status_to_byte(:iterating), do: 2
  defp status_to_byte(:needs_you), do: 3
  defp status_to_byte(:done), do: 4
  defp status_to_byte(:errored), do: 5
end
