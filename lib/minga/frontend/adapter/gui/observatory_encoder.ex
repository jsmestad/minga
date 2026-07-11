defmodule Minga.Frontend.Adapter.GUI.ObservatoryEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.Observatory
  alias Minga.RenderModel.UI.Observatory.Node

  @op_gui_observatory Opcodes.gui_observatory()
  @max_observatory_section_payload_bytes 65_000

  @spec encode(Observatory.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%Observatory{} = model, %Caches{} = caches) do
    fp = fingerprint(model)

    if fp != caches.last_observatory_fp do
      {encode_command(model), %{caches | last_observatory_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_command(Observatory.t()) :: binary()
  def encode_command(%Observatory{visible?: false}) do
    payload = Writer.section16(Writer.new(:gui_observatory), :header, 0x01, <<0::8, 0::16>>)
    encode_envelope(Writer.finish(payload))
  end

  def encode_command(%Observatory{visible?: true} = model) do
    header =
      :gui_observatory
      |> Writer.new()
      |> Writer.append(<<1::8>>)
      |> Writer.uint16(:node_count, Enum.count(model.nodes))
      |> Writer.finish()

    writer = Writer.section16(Writer.new(:gui_observatory), :header, 0x01, header)

    writer =
      encode_chunked_sections(writer, 0x02, Enum.map(model.nodes, &encode_observatory_node/1))

    writer =
      encode_chunked_sections(
        writer,
        0x03,
        Enum.map(model.nodes, &encode_observatory_sparkline/1)
      )

    writer |> Writer.finish() |> encode_envelope()
  end

  @spec encode_envelope(binary()) :: binary()
  defp encode_envelope(payload) do
    :gui_observatory
    |> Writer.new()
    |> Writer.append(<<@op_gui_observatory>>)
    |> Writer.payload32(:payload, payload)
    |> Writer.finish()
  end

  @spec fingerprint(Observatory.t()) :: term()
  defp fingerprint(%Observatory{visible?: false}), do: :hidden
  defp fingerprint(%Observatory{} = model), do: {model.visible?, model.nodes}

  @spec encode_chunked_sections(Writer.t(), non_neg_integer(), [binary()]) :: Writer.t()
  defp encode_chunked_sections(%Writer{} = writer, section_id, entries) do
    entries
    |> chunk_observatory_entries()
    |> Enum.reduce(writer, fn payload, acc ->
      Writer.section16(acc, :observatory_entries, section_id, payload)
    end)
  end

  @spec chunk_observatory_entries([binary()]) :: [binary()]
  defp chunk_observatory_entries(entries) do
    entries
    |> Enum.reduce({[], [], 0}, &chunk_observatory_entry/2)
    |> finish_observatory_entry_chunks()
  end

  @spec chunk_observatory_entry(binary(), {[binary()], [binary()], non_neg_integer()}) ::
          {[binary()], [binary()], non_neg_integer()}
  defp chunk_observatory_entry(entry, {chunks, current_entries, current_size}) do
    entry_size = byte_size(entry)
    append_observatory_entry(entry, entry_size, chunks, current_entries, current_size)
  end

  @spec append_observatory_entry(
          binary(),
          non_neg_integer(),
          [binary()],
          [binary()],
          non_neg_integer()
        ) :: {[binary()], [binary()], non_neg_integer()}
  defp append_observatory_entry(entry, entry_size, chunks, [], _current_size)
       when entry_size <= @max_observatory_section_payload_bytes do
    {chunks, [entry], entry_size}
  end

  defp append_observatory_entry(entry, entry_size, chunks, current_entries, current_size)
       when current_size + entry_size <= @max_observatory_section_payload_bytes do
    {chunks, [entry | current_entries], current_size + entry_size}
  end

  defp append_observatory_entry(entry, entry_size, chunks, current_entries, _current_size)
       when entry_size <= @max_observatory_section_payload_bytes do
    chunk = current_entries |> Enum.reverse() |> IO.iodata_to_binary()
    {[chunk | chunks], [entry], entry_size}
  end

  @spec finish_observatory_entry_chunks({[binary()], [binary()], non_neg_integer()}) :: [binary()]
  defp finish_observatory_entry_chunks({chunks, [], 0}), do: Enum.reverse(chunks)

  defp finish_observatory_entry_chunks({chunks, current_entries, _current_size}) do
    chunk = current_entries |> Enum.reverse() |> IO.iodata_to_binary()
    Enum.reverse([chunk | chunks])
  end

  @spec encode_observatory_node(Node.t()) :: binary()
  defp encode_observatory_node(%Node{} = node) do
    :gui_observatory
    |> Writer.new()
    |> Writer.string8(:node_pid, node.pid |> :erlang.pid_to_list() |> List.to_string())
    |> Writer.string8(:node_parent_pid, pid_to_bytes(node.parent_pid))
    |> Writer.string16(:node_name, node.name)
    |> Writer.uint8(:node_class, observatory_class_byte(node.process_class))
    |> Writer.uint8(:node_depth, node.depth)
    |> Writer.uint32(:node_memory, node.memory)
    |> Writer.uint16(:node_message_queue_len, node.message_queue_len)
    |> Writer.uint32(:node_reductions, node.reductions)
    |> Writer.finish()
  end

  @spec encode_observatory_sparkline(Node.t()) :: binary()
  defp encode_observatory_sparkline(%Node{} = node) do
    writer =
      :gui_observatory
      |> Writer.new()
      |> Writer.string8(:sparkline_pid, node.pid |> :erlang.pid_to_list() |> List.to_string())
      |> Writer.uint8(:sparkline_sample_count, Enum.count(node.sparkline_values))

    node.sparkline_values
    |> Enum.reduce(writer, fn value, acc ->
      Writer.uint16(acc, :sparkline_sample, round(value * 65_535.0))
    end)
    |> Writer.finish()
  end

  @spec pid_to_bytes(pid() | nil) :: binary()
  defp pid_to_bytes(nil), do: ""
  defp pid_to_bytes(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  @spec observatory_class_byte(term()) :: non_neg_integer()
  defp observatory_class_byte(:supervisor), do: 0
  defp observatory_class_byte(:buffer), do: 1
  defp observatory_class_byte(:agent_session), do: 2
  defp observatory_class_byte(:lsp), do: 3
  defp observatory_class_byte(:service), do: 4
  defp observatory_class_byte(:worker), do: 5
  defp observatory_class_byte(_unknown), do: 5
end
