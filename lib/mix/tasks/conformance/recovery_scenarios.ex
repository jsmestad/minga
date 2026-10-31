defmodule Mix.Tasks.Conformance.RecoveryScenarios do
  @moduledoc "Adversarial delivery inputs; every recovery response is captured from Renderer.Server."
  alias Mix.Tasks.Conformance.RecoveryDriver, as: Driver
  alias Minga.Frontend.Adapter.GUI.WindowEncoder
  alias Minga.RenderModel.Window
  alias Minga.RenderModel.Window.{Row, RowDelta, RowSplice}
  alias MingaEditor.Frontend.Protocol

  @doc "Builds fix-linked recovery and frontend-local transcripts."
  @spec build_all() :: [map()]
  def build_all do
    [retryable(), reference_miss(), stale_epoch(), resize(), dropped_ack(), local_scroll()]
  end

  defp retryable do
    Driver.with_driver([], fn driver ->
      initial = Driver.render(driver, 20)
      rejected = adversarial(initial, :base_sequence_mismatch, empty_state())
      Driver.record_delivery(driver, rejected)

      status =
        Driver.status(
          driver,
          {:frame_rejected, 1, 20, 0, :base_sequence_mismatch, :retryable_recovery}
        )

      recovery = Driver.capture(driver)

      transcript(
        "retryable_base_sequence",
        "72786a22f Fix macOS resync recovery: a missing committed base rejects atomically and the BEAM reserves generation 2, sequence 21.",
        [rejected, status, recovery, Driver.acknowledge(driver, recovery)]
      )
    end)
  end

  defp reference_miss do
    Driver.with_driver([], fn driver ->
      :ok = GenServer.call(driver.editor, {:api_execute_command, :split_vertical})
      first = Driver.render(driver, 20)
      first_ack = Driver.acknowledge(driver, first)
      warm = Driver.render(driver, 21)
      warm_ack = Driver.acknowledge(driver, warm)
      pending = Driver.render(driver, 22)
      missed = adversarial(pending, {:window_ref_miss, warm["expect"]}, warm["expect"])
      Driver.record_delivery(driver, missed)
      status = Driver.status(driver, {:window_ref_miss, 1, 22, 21, 1})
      recovery = Driver.capture(driver)

      transcript(
        "window_reference_miss",
        "1295ef63a fix(macos): recover failed frame resyncs: after acknowledging a real two-pane resident base, a missing retained row in pane 1 requests only that pane's full content; pane 2 and its content epoch remain unchanged.",
        [
          first,
          first_ack,
          warm,
          warm_ack,
          missed,
          status,
          recovery,
          Driver.acknowledge(driver, recovery)
        ]
      )
    end)
  end

  defp stale_epoch do
    Driver.with_driver([], fn driver ->
      initial = Driver.render(driver, 20)
      rejected = adversarial(initial, :base_sequence_mismatch, empty_state())
      Driver.record_delivery(driver, rejected)

      status =
        Driver.status(
          driver,
          {:frame_rejected, 1, 20, 0, :base_sequence_mismatch, :retryable_recovery}
        )

      recovery = Driver.capture(driver)
      ack = Driver.acknowledge(driver, recovery)
      stale = adversarial(initial, {:stale_content_epoch, recovery}, recovery["expect"])

      stale_status =
        Driver.status(
          driver,
          {:frame_rejected, 2, 22, 21, :window_epoch_mismatch, :retryable_recovery}
        )

      transcript(
        "stale_epoch_after_recovery",
        "72786a22f Fix macOS resync recovery: an old content epoch delivered after recovery must be stale_discarded without publishing or advancing last-good lineage.",
        [rejected, status, recovery, ack, stale, stale_status]
      )
    end)
  end

  defp resize do
    Driver.with_driver([], fn driver ->
      first = Driver.render(driver, 20)
      ack = Driver.acknowledge(driver, first)
      resize = Driver.resize(driver, 30, 80)
      next = Driver.render(driver, 21)

      transcript(
        "resize_between_frames",
        "f85298bd9 fix(macos): harden live-resize input handling per review: the reported 24-to-30 row fit reaches real EditorState, RenderPipeline and Layout before the next commit.",
        [first, ack, resize, next, Driver.acknowledge(driver, next)]
      )
    end)
  end

  defp dropped_ack do
    Driver.with_driver([], fn driver ->
      first = Driver.render(driver, 20)
      timeout = Driver.timeout(driver, first)
      recovery = Driver.capture(driver)

      transcript(
        "reattach_after_dropped_ack",
        "f618c71e2 fix(editor): recover stalled frontend frames: drop the applied acknowledgement and expire its exact lease; only the renderer timeout path authors the reattach keyframe.",
        [first, timeout, recovery, Driver.acknowledge(driver, recovery)]
      )
    end)
  end

  defp local_scroll do
    Driver.with_driver([], fn driver ->
      first = Driver.render(driver, 20)
      ack1 = Driver.acknowledge(driver, first)
      promoted = Driver.render(driver, 21)
      ack2 = Driver.acknowledge(driver, promoted)
      next = Driver.render(driver, 22)

      discarded? =
        promoted["expect"]["content_epochs"] != next["expect"]["content_epochs"] or
          promoted["expect"]["pane_rects"] != next["expect"]["pane_rects"]

      next = put_in(next, ["expect", "offset_discarded"], discarded?)
      pane = hd(next["expect"]["pane_rects"])["content_rect"]
      offset = if discarded?, do: 0, else: 1
      normalized = min(max(1 + offset, pane["row"]), pane["row"] + pane["height"] - 1)
      row = Enum.at(next["expect"]["rows"], normalized - pane["row"])

      click = %{
        "kind" => "click_after_settle",
        "window_id" => 1,
        "row" => 1,
        "col" => 10,
        "expect" => %{"normalized_buffer_line" => row["buf_line"]}
      }

      transcript(
        "wheel_during_commit_then_click",
        "559792551 fix(macos): reconcile local scroll with drawn snapshot (#3397), and 950ecc3fe fix(macos): normalize clicks during scroll settling (#2814): a wheel tick staged before commit survives an unchanged layout and the click resolves through that settled presentation.",
        [
          first,
          ack1,
          promoted,
          ack2,
          %{"kind" => "wheel", "window_id" => 1, "delta" => 1, "during" => "commit"},
          next,
          Driver.acknowledge(driver, next),
          click
        ]
      )
    end)
  end

  # These are adversarial INPUTS encoded with the production encoders. They are
  # deliberately not renderer responses. Recovery responses above are verbatim
  # Driver.capture batches, never synthesized or patched.
  defp adversarial(frame, fault, previous) do
    decoded =
      Protocol.decode_recorded_frame(
        Base.decode64!(frame["payload_base64"]),
        frame["command_sizes"]
      )

    commands = adversarial_commands(decoded, fault)
    sizes = Enum.map(commands, &byte_size/1)
    delivered = Protocol.decode_recorded_frame(IO.iodata_to_binary(commands), sizes)
    expect = Mix.Tasks.Conformance.RecoveryOracle.apply_frame(previous, delivered)

    after_commands =
      case fault do
        {:stale_content_epoch, _recovery} -> []
        _original_delivery -> frame["after_commands_base64"]
      end

    expect =
      Mix.Tasks.Conformance.RecoveryOracle.apply_side_channels(
        expect,
        Enum.map(after_commands, &Base.decode64!/1)
      )

    %{
      "kind" => "framed",
      "note" => "adversarial input: #{inspect(fault_name(fault))}",
      "payload_base64" => Base.encode64(IO.iodata_to_binary(commands)),
      "command_sizes" => Enum.map(commands, &byte_size/1),
      "after_commands_base64" => after_commands,
      "expect" => expect
    }
  end

  defp adversarial_commands(decoded, :base_sequence_mismatch) do
    [_begin | body] = decoded.commands
    [Protocol.encode_begin_frame(decoded.frame_seq, 19, decoded.generation) | body]
  end

  defp adversarial_commands(decoded, {:window_ref_miss, previous}) do
    [begin | body] = decoded.commands
    [begin, missing_retained_row(previous) | body]
  end

  defp adversarial_commands(decoded, {:stale_content_epoch, recovery}) do
    epoch = hd(decoded.windows).content_epoch
    [_begin | body] = replace_window_with_overlay(decoded.commands, epoch)
    body = List.replace_at(body, -1, Protocol.encode_commit_frame(22, 0))
    generation = recovery["expect"]["last_committed"]["generation"]
    [Protocol.encode_begin_frame(22, 21, generation) | body]
  end

  defp missing_retained_row(previous) do
    count = length(previous["window_rows"]["1"])

    row = %Row{
      row_id: Row.stable_id(:normal, 0xFFFF_FFFF, 0x0FFF_FFFF),
      row_type: :normal,
      buf_line: 0,
      text: "absent retained row",
      spans: [],
      content_hash: Row.compute_hash("absent retained row", [])
    }

    window = %Window{
      window_id: 1,
      content_kind: :buffer,
      rect: {0, 0, 80, 24},
      rows: [],
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block,
      content_epoch: previous["content_epochs"]["1"]
    }

    {:ok, delta} = RowDelta.new(count, count, [RowSplice.new(0, 1, [row])])

    {command, true} =
      WindowEncoder.encode_rows_delta(window, delta, %{row.row_id => row.content_hash})

    command
  end

  defp replace_window_with_overlay(commands, epoch) do
    window = %Window{
      window_id: 1,
      content_kind: :buffer,
      rect: {0, 0, 80, 24},
      rows: [],
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block,
      content_epoch: epoch
    }

    Enum.map(commands, fn
      <<0x80, _::binary>> -> WindowEncoder.encode_overlay_delta(window)
      command -> command
    end)
  end

  defp fault_name({name, _}), do: name
  defp fault_name(name), do: name
  defp empty_state, do: Mix.Tasks.Conformance.RecoveryOracle.empty()

  defp transcript(name, description, steps),
    do: %{
      "name" => name,
      "category" => "recovery",
      "description" => description,
      "frontends" => %{"swift" => true, "go" => true, "go_skip_reason" => nil},
      "steps" => steps
    }
end
