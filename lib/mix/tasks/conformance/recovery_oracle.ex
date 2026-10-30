defmodule Mix.Tasks.Conformance.RecoveryOracle do
  @moduledoc "BEAM expectations derived from decoded transaction lineage and retained window epochs."

  @doc "Returns the empty frontend's observable state."
  @spec empty() :: map()
  def empty do
    %{
      "rows" => [],
      "window_rows" => %{},
      "pane_rects" => [],
      "resident_rows" => 0,
      "content_epochs" => %{},
      "out_of_band" => %{},
      "last_committed" => %{"generation" => 0, "frame_seq" => 0}
    }
  end

  @doc "Calculates frontend publication without executing or copying renderer recovery policy."
  @spec apply_frame(map(), map()) :: map()
  def apply_frame(previous, decoded) do
    result = validate(previous, decoded, previous["last_committed"])

    publish(previous, decoded, result)
    |> Map.put("transaction_result", result)
    |> Map.put("keyframe", decoded.keyframe?)
    |> Map.put("base_frame_seq", decoded.base_frame_seq)
  end

  @doc "Observes captured lifecycle side channels independently of transaction acceptance."
  @spec apply_side_channels(map(), [binary()]) :: map()
  def apply_side_channels(state, batches) do
    effects = Enum.reduce(batches, Map.get(state, "out_of_band", %{}), &side_channel/2)
    Map.put(state, "out_of_band", effects)
  end

  defp side_channel(<<0x16, size::16, title::binary-size(size)>>, effects),
    do: Map.put(effects, "title", title)

  defp side_channel(<<0x17, background::24>>, effects),
    do: Map.put(effects, "window_background", background)

  # Other captured startup/lifecycle commands are still replayed by both clients;
  # these observations specifically lock the post-frame title/background effects.
  defp side_channel(_batch, effects), do: effects

  defp validate(_previous, %{base_frame_seq: base} = frame, %{"frame_seq" => seq} = last)
       when base != 0 and base != seq, do: rejected(frame, last, 4)

  defp validate(previous, frame, last) do
    case Enum.find(frame.overlays ++ frame.deltas, fn delta ->
           Map.get(previous["content_epochs"], to_string(delta.window_id)) != delta.content_epoch
         end) do
      nil ->
        validate_references(previous, frame, last)

      delta ->
        if Map.has_key?(previous["content_epochs"], to_string(delta.window_id)),
          do: rejected(frame, last, 8),
          else: missed(frame, last, delta.window_id)
    end
  end

  defp validate_references(previous, frame, last) do
    missing =
      Enum.find(frame.deltas, fn delta ->
        rows = Map.get(previous["window_rows"], to_string(delta.window_id), [])
        retained = Map.new(rows, &{{&1["row_id"], &1["content_hash"]}, &1})

        Enum.any?(inserted_rows(delta.change), fn
          {:reference, id, hash} -> not Map.has_key?(retained, {id, hash})
          _full -> false
        end)
      end)

    case missing do
      nil ->
        %{"kind" => "applied", "generation" => frame.generation, "frame_seq" => frame.frame_seq}

      delta ->
        missed(frame, last, delta.window_id)
    end
  end

  defp inserted_rows({:snapshot, rows}), do: rows

  defp inserted_rows({:splices, _base, _result, splices}),
    do: Enum.flat_map(splices, fn {_start, _delete, rows} -> rows end)

  defp rejected(frame, last, reason),
    do: %{
      "kind" => "rejected",
      "generation" => frame.generation,
      "frame_seq" => frame.frame_seq,
      "last_applied_frame_seq" => last["frame_seq"],
      "reason" => reason,
      "disposition" => 1
    }

  defp missed(frame, last, window_id),
    do: %{
      "kind" => "window_ref_miss",
      "generation" => frame.generation,
      "frame_seq" => frame.frame_seq,
      "last_applied_frame_seq" => last["frame_seq"],
      "window_id" => window_id
    }

  defp publish(previous, _frame, %{"kind" => kind}) when kind != "applied", do: previous

  defp publish(previous, frame, result) do
    windows =
      Enum.reduce(frame.windows, previous["window_rows"], fn window, acc ->
        Map.put(acc, to_string(window.window_id), window.rows)
      end)

    windows =
      Enum.reduce(frame.deltas, windows, fn delta, acc ->
        id = to_string(delta.window_id)
        Map.update!(acc, id, &apply_change(&1, delta.change))
      end)

    panes = Map.new(previous["pane_rects"], &{&1["window_id"], &1})

    panes =
      Enum.reduce(frame.windows ++ frame.deltas, panes, fn window, acc ->
        case window.pane_rects do
          nil -> acc
          rects -> Map.put(acc, window.window_id, rects)
        end
      end)

    epochs =
      Enum.reduce(frame.windows, previous["content_epochs"], fn window, acc ->
        Map.put(acc, to_string(window.window_id), window.content_epoch)
      end)

    rows = Map.get(windows, "1", [])

    %{
      "rows" => rows,
      "window_rows" => windows,
      "pane_rects" => panes |> Enum.sort() |> Enum.map(&elem(&1, 1)),
      "resident_rows" => length(rows),
      "content_epochs" => epochs,
      "out_of_band" => Map.get(previous, "out_of_band", %{}),
      "last_committed" => Map.drop(result, ["kind"])
    }
  end

  defp apply_change(previous, {:snapshot, entries}), do: resolve(entries, previous)

  defp apply_change(previous, {:splices, base, result, splices}) do
    ^base = length(previous)

    rows =
      Enum.reduce(splices, previous, fn {start, delete, insert}, rows ->
        Enum.take(rows, start) ++ resolve(insert, previous) ++ Enum.drop(rows, start + delete)
      end)

    ^result = length(rows)
    rows
  end

  defp resolve(entries, previous) do
    retained = Map.new(previous, &{{&1["row_id"], &1["content_hash"]}, &1})

    Enum.map(entries, fn
      {:reference, id, hash} -> Map.fetch!(retained, {id, hash})
      row -> row
    end)
  end
end
