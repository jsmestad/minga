defmodule Minga.Conformance.RecoveryCorpusTest do
  use ExUnit.Case, async: true

  alias Minga.Protocol.Opcodes
  alias MingaEditor.Frontend.Protocol
  alias Mix.Tasks.Conformance.RecoveryDriver, as: Driver
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

    assert [_, _] = warm["expect"]["pane_rects"]
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

  test "a pane reference miss replays a sibling's rejected same-row-count edit and semantics" do
    Driver.with_driver([], fn driver ->
      :ok = GenServer.call(driver.editor, {:api_execute_command, :split_vertical})
      first = Driver.render(driver, 20)
      Driver.acknowledge(driver, first)
      warm = Driver.render(driver, 21)
      Driver.acknowledge(driver, warm)

      previous_rows = warm["expect"]["window_rows"]["2"]
      assert [%{"text" => "recovery line 0"} | _] = previous_rows
      assert {_base, warm_revision, _row_revision} = semantic_revisions(decode(warm), 2)

      {:ok, buffer} = GenServer.call(driver.editor, :api_active_buffer)
      :ok = Minga.Buffer.apply_edit(buffer, 0, 0, 0, 1, "RE")
      pending = Driver.render(driver, 22)
      decoded_pending = decode(pending)
      edited_rows = pending["expect"]["window_rows"]["2"]
      assert [%{"text" => "REcovery line 0"} | _] = edited_rows
      assert length(edited_rows) == length(previous_rows)
      pending_revisions = semantic_revisions(decoded_pending, 2)
      assert {^warm_revision, _, _} = pending_revisions

      # The shared edit reaches both panes, but only pane 1 has lost its retained base.
      missing_pane = update_in(warm["expect"], ["content_epochs"], &Map.delete(&1, "1"))
      rejected = RecoveryOracle.apply_frame(missing_pane, decoded_pending)

      assert rejected["transaction_result"] == %{
               "kind" => "window_ref_miss",
               "generation" => 1,
               "frame_seq" => 22,
               "last_applied_frame_seq" => 21,
               "window_id" => 1
             }

      assert rejected["window_rows"]["2"] == previous_rows
      Driver.record_delivery(driver, %{"expect" => rejected})
      Driver.status(driver, {:window_ref_miss, 1, 22, 21, 1})

      recovery = Driver.capture(driver)
      decoded_recovery = decode(recovery)
      assert %{generation: 1, base_frame_seq: 21, frame_seq: 23} = decoded_recovery
      assert [%{window_id: 1, full_refresh?: true}] = decoded_recovery.windows
      assert recovery["expect"]["window_rows"]["2"] == edited_rows
      assert recovery["expect"]["content_epochs"]["2"] == warm["expect"]["content_epochs"]["2"]
      assert semantic_revisions(decoded_recovery, 2) == pending_revisions

      assert %{"event" => "frame_applied", "frame_seq" => 23} =
               Driver.acknowledge(driver, recovery)
    end)
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

  defp semantic_revisions(frame, window_id) do
    opcode = Opcodes.gui_resident_semantics()

    Enum.find_value(frame.commands, fn
      <<^opcode, _size::32, _version, _mode, ^window_id::16, _epoch::32, base::32, revision::32,
        row_revision::32, _::binary>> ->
        {base, revision, row_revision}

      _ ->
        nil
    end)
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
