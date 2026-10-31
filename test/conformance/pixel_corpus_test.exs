defmodule Minga.Conformance.PixelCorpusTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Protocol

  @corpus Path.expand("corpus", __DIR__)
  @fixes %{
    "pixels_background_fill" => "6ab625b2c",
    "pixels_spaced_rows" => "966352a7c",
    "pixels_no_stale_glyphs_after_local_scroll" => "559792551"
  }

  test "all three pixel transcripts preserve Go model coverage and encoded production frames" do
    index = @corpus |> Path.join("index.json") |> File.read!() |> JSON.decode!()
    entries = Enum.filter(index["transcripts"], &(&1["category"] == "pixels"))
    assert Enum.sort(Enum.map(entries, & &1["name"])) == Enum.sort(Map.keys(@fixes))

    for entry <- entries do
      assert entry["swift"] == true
      assert entry["go"] == true
      transcript = @corpus |> Path.join(entry["file"]) |> File.read!() |> JSON.decode!()
      assert transcript["description"] =~ Map.fetch!(@fixes, entry["name"])
      assert Enum.any?(transcript["steps"], &get_in(&1, ["expect", "pixels"]))

      Enum.reduce(transcript["steps"], %{"rows" => [], "pane_rects" => []}, fn step, previous ->
        if step["kind"] == "framed" do
          batch = Base.decode64!(step["payload_base64"])
          assert Enum.sum(step["command_sizes"]) == byte_size(batch)
          decoded = Protocol.decode_recorded_frame(batch, step["command_sizes"])
          expect = step["expect"]
          assert expect["transaction_result"]["kind"] == "applied"
          assert decoded.generation == expect["transaction_result"]["generation"]
          assert decoded.frame_seq == expect["transaction_result"]["frame_seq"]

          case decoded.windows do
            [window | _] ->
              assert window.rows == expect["rows"]
              assert Enum.map(decoded.windows, & &1.pane_rects) == expect["pane_rects"]

            [] ->
              assert expect["rows"] == previous["rows"]
              assert expect["pane_rects"] == previous["pane_rects"]
          end

          assert expect["resident_rows"] == length(expect["rows"])

          for region <- expect["pixels"] || [] do
            assert step["swift_only"] == true
            assert region["assert"] in ["color", "occupied", "empty"]
            assert region["color"] =~ ~r/^0x[0-9A-Fa-f]{6}$/
            assert region["tolerance"] == 0.02
            assert is_binary(region["region"]) and region["region"] != ""
            [row, col, rows, cols] = region["cells"]
            assert rows > 0 and cols > 0

            assert Enum.any?(expect["pane_rects"], fn pane ->
                     rect = pane["text_rect"]

                     row >= rect["row"] and col >= rect["col"] and
                       row + rows <= rect["row"] + rect["height"] and
                       col + cols <= rect["col"] + rect["width"] and
                       row + rows - rect["row"] <= length(expect["rows"])
                   end)
          end

          expect
        else
          previous
        end
      end)
    end
  end
end
