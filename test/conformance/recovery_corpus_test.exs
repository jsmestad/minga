defmodule Minga.Conformance.RecoveryCorpusTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.Protocol
  alias Mix.Tasks.Conformance.RecoveryOracle

  @corpus Path.join(__DIR__, "corpus")
  @names ~w(retryable_base_sequence window_reference_miss stale_epoch_after_recovery resize_between_frames reattach_after_dropped_ack)

  test "the index enumerates every required fix-linked recovery transcript for both clients" do
    index = @corpus |> Path.join("index.json") |> File.read!() |> JSON.decode!()
    recovery = Enum.filter(index["transcripts"], &(&1["category"] == "recovery"))
    assert MapSet.subset?(MapSet.new(@names), MapSet.new(recovery, & &1["name"]))

    for entry <- recovery do
      assert entry["swift"] and entry["go"]
      transcript = @corpus |> Path.join(entry["file"]) |> File.read!() |> JSON.decode!()
      assert transcript["description"] =~ ~r/\b[0-9a-f]{9}\b/
      replay(transcript["steps"], RecoveryOracle.empty())
    end
  end

  test "retryable recovery reserves exactly generation two and sequence twenty-one" do
    steps = load("retryable_base_sequence")
    [rejected, status, recovery | _] = steps
    assert rejected["expect"]["transaction_result"]["reason"] == 4
    assert status["event"] == "frame_rejected"
    assert recovery["expect"]["last_committed"] == %{"generation" => 2, "frame_seq" => 21}
    assert recovery["expect"]["force_keyframe"]
    assert recovery["expect"]["keyframe"]
  end

  test "a retained reference miss hydrates only one pane from a nonzero acknowledged base" do
    [_first, _first_ack, warm, _warm_ack, miss, status, recovery, _ack] =
      load("window_reference_miss")

    assert length(warm["expect"]["pane_rects"]) == 2
    assert status["last_applied_frame_seq"] == 21
    assert miss["expect"]["last_committed"] == warm["expect"]["last_committed"]
    assert miss["expect"]["transaction_result"]["kind"] == "window_ref_miss"
    assert recovery["expect"]["last_committed"] == %{"generation" => 1, "frame_seq" => 23}
    assert recovery["expect"]["base_frame_seq"] == 21
    refute recovery["expect"]["force_keyframe"]
    refute recovery["expect"]["keyframe"]
    assert recovery["expect"]["window_rows"]["2"] == warm["expect"]["window_rows"]["2"]
    assert recovery["expect"]["content_epochs"]["2"] == warm["expect"]["content_epochs"]["2"]
    assert [%{window_id: 1, full_refresh?: true}] = decode(recovery).windows
    assert recovery["expect"]["resident_rows"] > 0
  end

  test "stale content cannot advance the recovered commit" do
    steps = load("stale_epoch_after_recovery")
    stale = Enum.find(steps, &(&1["expect"]["transaction_result"]["reason"] == 8))
    assert stale["expect"]["last_committed"] == %{"generation" => 2, "frame_seq" => 21}
  end

  test "initial adversarial delivery preserves side channels but stale replay does not repeat them" do
    for name <- ~w(retryable_base_sequence stale_epoch_after_recovery) do
      [initial | _] = steps = load(name)
      assert [_ | _] = initial["after_commands_base64"]
      assert is_binary(initial["expect"]["out_of_band"]["title"])
      assert is_integer(initial["expect"]["out_of_band"]["window_background"])

      if name == "stale_epoch_after_recovery" do
        stale = Enum.find(steps, &(&1["expect"]["transaction_result"]["reason"] == 8))
        assert stale["after_commands_base64"] == []
      end
    end
  end

  test "resize records the frontend row fit and real pipeline geometry" do
    [first, _ack, resize, next | _] = load("resize_between_frames")
    assert resize == %{"kind" => "resize", "rows" => 30, "cols" => 80}
    [before] = first["expect"]["pane_rects"]
    [after_resize] = next["expect"]["pane_rects"]
    assert after_resize["total_rect"]["height"] - before["total_rect"]["height"] == 6
    replay([first, resize, next], RecoveryOracle.empty())
  end

  defp load(name) do
    @corpus
    |> Path.join("recovery/#{name}.json")
    |> File.read!()
    |> JSON.decode!()
    |> Map.fetch!("steps")
  end

  defp decode(step) do
    Protocol.decode_recorded_frame(
      Base.decode64!(step["payload_base64"]),
      step["command_sizes"]
    )
  end

  defp replay([], _state), do: :ok

  defp replay([%{"kind" => "framed"} = step | rest], state) do
    actual =
      state
      |> RecoveryOracle.apply_frame(decode(step))
      |> RecoveryOracle.apply_side_channels(
        Enum.map(step["after_commands_base64"], &Base.decode64!/1)
      )

    expect = step["expect"]

    for key <-
          ~w(transaction_result last_committed resident_rows rows window_rows content_epochs pane_rects keyframe base_frame_seq out_of_band) do
      assert actual[key] == expect[key], "BEAM oracle disagrees on #{key}"
    end

    replay(rest, actual)
  end

  defp replay([_input | rest], state), do: replay(rest, state)
end
