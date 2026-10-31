defmodule MingaEditor.Frontend.Protocol.RecordedFrame do
  @moduledoc "Decodes captured transaction boundaries and window snapshots for the BEAM conformance oracle."
  import Bitwise
  alias MingaEditor.Frontend.FrameTransaction

  @doc "Decodes a verbatim batch using command boundaries captured before Manager admission."
  @spec decode(binary(), [pos_integer()]) :: map()
  def decode(batch, sizes) do
    {commands, <<>>} =
      Enum.map_reduce(sizes, batch, fn size, rest ->
        <<command::binary-size(^size), rest::binary>> = rest
        {command, rest}
      end)

    :ok = FrameTransaction.validate(commands)
    [<<0x10, seq::32, base::32, generation::32>> | _] = commands
    <<0x11, ^seq::32, _input_seq::32>> = List.last(commands)

    windows =
      Enum.flat_map(commands, fn
        <<0x80, length::32, payload::binary-size(length)>> -> [window(payload)]
        _ -> []
      end)

    overlays =
      Enum.flat_map(commands, fn
        <<0xA0, id::16, epoch::32, _::binary>> -> [%{window_id: id, content_epoch: epoch}]
        _ -> []
      end)

    deltas =
      Enum.flat_map(commands, fn
        <<opcode, payload::binary>> when opcode in [0xA1, 0xA2] -> [delta(payload)]
        _ -> []
      end)

    %{
      generation: generation,
      frame_seq: seq,
      base_frame_seq: base,
      keyframe?: base == 0,
      commands: commands,
      windows: windows,
      overlays: overlays,
      deltas: deltas
    }
  end

  defp window(<<count, rest::binary>>) do
    {sections, <<>>} = sections(rest, count, %{})

    <<window_id::16, flags, _cursor::binary-size(7), epoch::32, _::binary>> =
      Map.fetch!(sections, 1)

    <<count::32, row_payload::binary>> = Map.fetch!(sections, 2)
    {rows, <<>>} = rows(row_payload, count, [])

    %{
      window_id: window_id,
      full_refresh?: (flags &&& 1) == 1,
      content_epoch: epoch,
      rows: rows,
      pane_rects: geometry(Map.fetch!(sections, 8)),
      scroll: Map.get(sections, 10)
    }
  end

  defp delta(<<count, rest::binary>>) do
    {sections, <<>>} = sections(rest, count, %{})
    <<id::16, epoch::32, _::binary>> = Map.fetch!(sections, 1)
    change = delta_rows(sections)

    %{
      window_id: id,
      content_epoch: epoch,
      change: change,
      pane_rects: optional_geometry(Map.get(sections, 8))
    }
  end

  defp optional_geometry(nil), do: nil
  defp optional_geometry(payload), do: geometry(payload)

  defp delta_rows(%{11 => <<base::32, result::32, count::32, rest::binary>>}) do
    {splices, <<>>} = splices(rest, count, [])
    {:splices, base, result, splices}
  end

  defp delta_rows(%{2 => <<count::32, rest::binary>>}) do
    {entries, <<>>} = entries(rest, count, [])
    {:snapshot, entries}
  end

  defp splices(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp splices(<<start::32, delete::32, count::32, rest::binary>>, remaining, acc) do
    {insert, rest} = entries(rest, count, [])
    splices(rest, remaining - 1, [{start, delete, insert} | acc])
  end

  defp entries(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp entries(<<0, id::64, hash::32, rest::binary>>, count, acc),
    do: entries(rest, count - 1, [{:reference, Integer.to_string(id), hash} | acc])

  defp entries(<<1, rest::binary>>, count, acc) do
    {[row], rest} = rows(rest, 1, [])
    entries(rest, count - 1, [row | acc])
  end

  defp sections(rest, 0, acc), do: {acc, rest}

  defp sections(<<id, length::32, body::binary-size(length), rest::binary>>, count, acc),
    do: sections(rest, count - 1, Map.put(acc, id, body))

  defp rows(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp rows(
         <<_type, id::64, line::32, hash::32, length::32, text::binary-size(length), spans::16,
           rest::binary>>,
         count,
         acc
       ) do
    <<_spans::binary-size(^spans * 13), rest::binary>> = rest

    row = %{
      "row_id" => Integer.to_string(id),
      "buf_line" => line,
      "content_hash" => hash,
      "text" => text
    }

    rows(rest, count - 1, [row | acc])
  end

  defp geometry(
         <<id::16, total::binary-size(8), content::binary-size(8), text::binary-size(8),
           gutter::binary-size(8), _::binary>>
       ) do
    %{
      "window_id" => id,
      "total_rect" => rect(total),
      "content_rect" => rect(content),
      "text_rect" => rect(text),
      "gutter_rect" => rect(gutter)
    }
  end

  defp rect(<<row::16, col::16, width::16, height::16>>),
    do: %{"row" => row, "col" => col, "width" => width, "height" => height}
end
