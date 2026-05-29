defmodule Minga.Frontend.Adapter.GUI.ObservatoryEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.Observatory
  alias Minga.RenderModel.UI.Observatory.Node

  @op_gui_observatory Opcodes.gui_observatory()
  @max_observatory_section_payload_bytes 65_000
  @max_observatory_name_bytes 64_000

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
    payload = Wire.encode_section(0x01, <<0::8, 0::16>>)
    <<@op_gui_observatory, byte_size(payload)::32, payload::binary>>
  end

  def encode_command(%Observatory{visible?: true} = model) do
    node_entries = Enum.map(model.nodes, &encode_observatory_node/1)
    sparkline_entries = Enum.map(model.nodes, &encode_observatory_sparkline/1)

    sections = [
      Wire.encode_section(0x01, <<1::8, length(model.nodes)::16>>),
      encode_chunked_sections(0x02, node_entries),
      encode_chunked_sections(0x03, sparkline_entries)
    ]

    payload = IO.iodata_to_binary(sections)
    <<@op_gui_observatory, byte_size(payload)::32, payload::binary>>
  end

  @spec fingerprint(Observatory.t()) :: term()
  defp fingerprint(%Observatory{visible?: false}), do: :hidden
  defp fingerprint(%Observatory{} = model), do: {model.visible?, model.nodes}

  @spec encode_chunked_sections(non_neg_integer(), [binary()]) :: iodata()
  defp encode_chunked_sections(section_id, entries) do
    entries
    |> chunk_observatory_entries()
    |> Enum.map(&Wire.encode_section(section_id, &1))
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
    pid_bytes = node.pid |> :erlang.pid_to_list() |> List.to_string()
    parent_bytes = pid_to_bytes(node.parent_pid)
    name_bytes = Wire.utf8_prefix_bytes(node.name, @max_observatory_name_bytes)

    <<byte_size(pid_bytes)::8, pid_bytes::binary, byte_size(parent_bytes)::8,
      parent_bytes::binary, byte_size(name_bytes)::16, name_bytes::binary,
      observatory_class_byte(node.process_class)::8, node.depth::8,
      Wire.clamp_u32(node.memory)::32, Wire.clamp_u16(node.message_queue_len)::16,
      Wire.clamp_u32(node.reductions)::32>>
  end

  @spec encode_observatory_sparkline(Node.t()) :: binary()
  defp encode_observatory_sparkline(%Node{} = node) do
    pid_bytes = node.pid |> :erlang.pid_to_list() |> List.to_string()
    values = Enum.take(node.sparkline_values, 255)
    sample_bytes = Enum.map(values, &encode_float16/1)

    <<byte_size(pid_bytes)::8, pid_bytes::binary, length(values)::8,
      IO.iodata_to_binary(sample_bytes)::binary>>
  end

  @spec encode_float16(float()) :: binary()
  defp encode_float16(value) do
    clamped = max(0.0, min(1.0, value))
    scaled = round(clamped * 65_535.0)
    <<scaled::16>>
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
