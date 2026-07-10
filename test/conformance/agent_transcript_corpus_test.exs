defmodule Minga.Conformance.AgentTranscriptCorpusTest do
  # BEAM-side oracle for the resident agent-transcript conformance family (0x86,
  # #2654 slice 5). It re-decodes the exact bytes `mix conformance.gen` emitted and
  # asserts they carry precisely what each `transcript_frame` step's
  # `expect.transcript` claims (epoch, mode, truncated, ordered message ids). This
  # is the third leg of the parity triangle: the Swift and Go runners decode+apply
  # the same corpus, and this test guarantees the fixtures are not stale or
  # hand-edited relative to the encoder. Regenerate with `mix conformance.gen` if it
  # fails after an encoder change.
  use ExUnit.Case, async: true

  alias Minga.Protocol.Opcodes

  @op Opcodes.gui_agent_transcript()
  @mode_full_replace 0
  @mode_append 1
  @corpus_dir Path.expand("corpus", __DIR__)
  @index_path Path.join(@corpus_dir, "index.json")
  @external_resource @index_path

  # Enumerated at compile time so each chat transcript gets its own test. The
  # module body cannot call the module's own private helpers, so the load is
  # inlined here rather than routed through load_json/1.
  @chat_transcripts @index_path
                    |> File.read!()
                    |> JSON.decode!()
                    |> Map.fetch!("transcripts")
                    |> Enum.filter(&(&1["category"] == "chat"))

  defp load_json(path), do: path |> File.read!() |> JSON.decode!()

  # Decodes one framed gui_agent_transcript message into a plain map.
  defp decode(<<@op, len::32, payload::binary>>) do
    ^len = byte_size(payload)
    <<version::8, mode::8, epoch::32, truncated::8, rest::binary>> = payload
    decode_mode(%{version: version, mode: mode, epoch: epoch, truncated: truncated == 1}, rest)
  end

  defp decode_mode(%{mode: @mode_full_replace} = acc, <<count::32, rest::binary>>) do
    {entries, <<>>} = decode_entries(rest, count, [])
    Map.merge(acc, %{trim_front: 0, base: 0, count: count, entries: entries})
  end

  defp decode_mode(%{mode: @mode_append} = acc, <<trim::32, base::32, count::32, rest::binary>>) do
    {entries, <<>>} = decode_entries(rest, count, [])
    Map.merge(acc, %{trim_front: trim, base: base, count: count, entries: entries})
  end

  defp decode_entries(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_entries(<<id::32, blen::32, body::binary-size(blen), rest::binary>>, n, acc) do
    decode_entries(rest, n - 1, [{id, body} | acc])
  end

  # Folds the frame sequence exactly as a frontend store does, so the ORACLE also
  # asserts the resident id set the expectations claim (not just the wire), which
  # catches trim_front/base_count math drift the raw wire alone would not.
  defp apply_frame(_store, %{mode: @mode_full_replace, entries: entries, epoch: epoch}) do
    %{epoch: epoch, ids: Enum.map(entries, &elem(&1, 0))}
  end

  defp apply_frame(%{ids: ids} = store, %{mode: @mode_append} = frame) do
    kept = Enum.slice(ids, frame.trim_front, frame.base)

    {new_ids, _seen} =
      Enum.reduce(frame.entries, {[], MapSet.new(kept)}, fn {id, _body}, {acc, seen} ->
        if MapSet.member?(seen, id) do
          {acc, seen}
        else
          {[id | acc], MapSet.put(seen, id)}
        end
      end)

    merged = kept ++ Enum.reverse(new_ids)

    %{store | epoch: (frame.epoch != 0 && frame.epoch) || store.epoch, ids: merged}
  end

  test "the corpus enumerates chat transcripts" do
    assert @chat_transcripts != [], "no chat transcripts in the corpus; run `mix conformance.gen`"
  end

  for transcript <- @chat_transcripts do
    @transcript transcript

    test "chat corpus #{@transcript["name"]} frames decode to their expectations" do
      %{"file" => file} = @transcript
      steps = @corpus_dir |> Path.join(file) |> load_json() |> Map.fetch!("steps")

      final_store =
        steps
        |> Enum.filter(&(&1["kind"] == "transcript_frame"))
        |> Enum.reduce(%{epoch: nil, ids: []}, fn step, store ->
          frame = step |> Map.fetch!("payload_base64") |> Base.decode64!() |> decode()
          want = step["expect"]["transcript"]

          assert frame.epoch == want["epoch"],
                 "#{@transcript["name"]} #{step["note"]}: epoch #{frame.epoch} != #{want["epoch"]}"

          assert frame.truncated == want["truncated"],
                 "#{@transcript["name"]} #{step["note"]}: truncated #{frame.truncated} != #{want["truncated"]}"

          store = apply_frame(store, frame)

          assert store.ids == want["message_ids"],
                 "#{@transcript["name"]} #{step["note"]}: resident ids #{inspect(store.ids)} != #{inspect(want["message_ids"])}"

          assert length(store.ids) == want["count"],
                 "#{@transcript["name"]} #{step["note"]}: count #{length(store.ids)} != #{want["count"]}"

          store
        end)

      assert final_store.ids != []
    end
  end
end
