defmodule Mix.Tasks.Conformance.Gen do
  @shortdoc "Generates the frontend conformance transcript corpus from the real encoder"

  @moduledoc """
  Generates the shared frontend conformance transcript corpus (#2667).

  This task drives the real `Minga.Frontend.Adapter.GUI.WindowEncoder` and the
  real `Minga.RenderModel.Window` frame model to produce framed binary payload
  sequences plus expected-outcome JSON. The Swift (`macos/Tests/MingaTests`) and
  Go (`go/tui/internal/ui`) test suites both execute this corpus so a divergence
  between frontends fails a build instead of surfacing as a rendering bug.

  Because every payload is produced by the real `WindowEncoder`, fixtures cannot
  drift from the wire format (AC4). Expected outcomes are derived from the same
  render-model structs the encoder encoded, and from the documented reconciliation
  rule in `docs/GUI_PROTOCOL.md` (the offset-transform reconciliation key plus the
  `scroll_seq` strictly-newer rule). No wire bytes are hand-typed.

  ## Usage

      mix conformance.gen

  Writes the corpus under `test/conformance/corpus/`. The format is documented in
  `test/conformance/corpus/README.md`.
  """

  use Mix.Task

  alias Minga.Config.Options
  alias Minga.Frontend.Adapter.GUI.AgentChatMessageCodec
  alias Minga.Frontend.Adapter.GUI.AgentTranscriptEncoder
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.WindowEncoder
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.AgentChat
  alias Minga.RenderModel.Window, as: RW
  alias Minga.RenderModel.Window.GutterMetrics
  alias Minga.RenderModel.Window.PaneGeometry
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.ScrollPresentation
  alias Minga.RenderModel.Window.Viewport

  @corpus_dir "test/conformance/corpus"

  @op_window_content 0x80
  @op_overlay_delta 0xA0
  @op_viewport_delta 0xA1
  @op_rows_delta 0xA2
  @op_gui_agent_transcript Opcodes.gui_agent_transcript()

  @typep sp :: ScrollPresentation.t()
  @typep transcript :: %{optional(String.t()) => term()}

  @doc "Builds and writes the full conformance corpus."
  @spec run([String.t()]) :: :ok
  def run(_args) do
    File.mkdir_p!(Path.join(@corpus_dir, "store"))
    File.mkdir_p!(Path.join(@corpus_dir, "input"))
    File.mkdir_p!(Path.join(@corpus_dir, "chat"))

    # The chat family uses the semantic transcript selector. It reads the
    # resident byte-cap option from Config, so start its ETS-backed server for
    # this run and stop it afterward when this task started it.
    started? = ensure_options_server()

    try do
      transcripts = build_all()
      Enum.each(transcripts, &write_transcript/1)
      write_index(transcripts)

      Mix.shell().info(
        "conformance.gen: wrote #{length(transcripts)} transcripts to #{@corpus_dir}"
      )
    after
      if started?, do: GenServer.stop(Options.default_server())
    end

    :ok
  end

  # Starts the default Config.Options server if one is not already running.
  # Returns true when this task started it (so the caller stops it).
  @spec ensure_options_server() :: boolean()
  defp ensure_options_server do
    case Options.start_link() do
      {:ok, _pid} -> true
      {:error, {:already_started, _pid}} -> false
    end
  end

  @spec build_all() :: [transcript()]
  defp build_all do
    [
      keyframe_decode(),
      rows_delta_ref_resolution(),
      ref_miss_full_recovery(),
      cursor_only_overlay_delta(),
      layout_generation_full_replace(),
      reset_required_discard(),
      drag_selection_active_offset(),
      hml_after_scroll_report(),
      scroll_seq_strictly_newer_discard(),
      same_top_jump_discards(),
      wheel_momentum_during_ctrl_d(),
      append_while_scrolled_up(),
      pin_to_bottom_resume(),
      session_switch_full_replace(),
      trim_front_eviction_midstream(),
      epoch_flip_midstream(),
      streaming_tail_patch()
    ]
  end

  # ── Store lifecycle transcripts (AC1) ─────────────────────────────────────

  @spec keyframe_decode() :: transcript()
  defp keyframe_decode do
    rows = rows_for(0, 5)
    win = window(window_id: 1, rows: rows, top: 0, epoch: 1, full_refresh: true, scroll_seq: 0)

    transcript(
      "keyframe_decode",
      "store",
      %{swift: true, go: true},
      "First 0x80 keyframe decodes to a resident row set keyed by row_id + content_hash, with the committed anchor and a reset_required discard (full_refresh).",
      [
        frame(@op_window_content, "keyframe", WindowEncoder.encode_window_content(win), %{
          "store_present" => true,
          "rows" => rows_expect(rows),
          "anchor" => anchor(win),
          "cursor_row" => 0
        })
      ]
    )
  end

  @spec rows_delta_ref_resolution() :: transcript()
  defp rows_delta_ref_resolution do
    rows1 = rows_for(0, 5)
    win1 = window(window_id: 1, rows: rows1, top: 0, epoch: 1, full_refresh: true)

    # Row 2 gets new content; the other four stay retained and encode as refs.
    changed = row(2, "changed line 2")
    rows2 = List.replace_at(rows1, 2, changed)
    retained = rows1 |> List.delete_at(2) |> hashes()
    win2 = window(window_id: 1, rows: rows2, top: 0, epoch: 1, full_refresh: false)
    {rows_delta, true} = WindowEncoder.encode_rows_delta(win2, retained)

    transcript(
      "rows_delta_ref_resolution",
      "store",
      %{swift: true, go: true},
      "A 0xA2 row-delta resolves four retained refs by row_id + content_hash and one full row, producing the same resident set the encoder built.",
      [
        frame(@op_window_content, "keyframe", WindowEncoder.encode_window_content(win1), %{
          "store_present" => true,
          "rows" => rows_expect(rows1)
        }),
        # Inject a live offset first so offset_discarded => false is a real
        # assertion that the row-delta PRESERVED the offset, not a trivial pass on
        # a window that never had one (#2667 coverage note).
        inject_offset(1, 2, 0),
        frame(@op_rows_delta, "rows-delta (4 refs + 1 full)", rows_delta, %{
          "store_present" => true,
          "rows" => rows_expect(rows2),
          "anchor" => anchor(win2),
          "offset_discarded" => discarded?(scroll(win1), scroll(win2))
        })
      ]
    )
  end

  @spec ref_miss_full_recovery() :: transcript()
  defp ref_miss_full_recovery do
    rows1 = rows_for(0, 5)
    win1 = window(window_id: 1, rows: rows1, top: 0, epoch: 1, full_refresh: true)

    # The delta references a row (buf_line 99) the frontend never stored, so the
    # ref cannot resolve and the retained window must be dropped.
    absent = row(99, "phantom line 99")
    rows2 = [Enum.at(rows1, 0), absent]
    retained = hashes([Enum.at(rows1, 0), absent])
    win2 = window(window_id: 1, rows: rows2, top: 0, epoch: 1, full_refresh: false)
    {rows_delta, true} = WindowEncoder.encode_rows_delta(win2, retained)

    rows3 = rows_for(0, 5)
    win3 = window(window_id: 1, rows: rows3, top: 0, epoch: 2, full_refresh: true)

    transcript(
      "ref_miss_full_recovery",
      "store",
      %{swift: true, go: true},
      "A 0xA2 ref to an unretained row_id drops the resident window; the following 0x80 recovery frame (new epoch) rebuilds it.",
      [
        frame(@op_window_content, "keyframe", WindowEncoder.encode_window_content(win1), %{
          "store_present" => true,
          "rows" => rows_expect(rows1)
        }),
        frame(@op_rows_delta, "rows-delta with unresolvable ref", rows_delta, %{
          "store_present" => false
        }),
        frame(
          @op_window_content,
          "recovery keyframe",
          WindowEncoder.encode_window_content(win3),
          %{
            "store_present" => true,
            "rows" => rows_expect(rows3),
            "anchor" => anchor(win3)
          }
        )
      ]
    )
  end

  @spec cursor_only_overlay_delta() :: transcript()
  defp cursor_only_overlay_delta do
    rows = rows_for(0, 5)
    # Non-reset keyframe: a local offset only ever exists on a committed
    # non-reset frame, so the injected-offset coverage of offset_discarded => false
    # (a cursor-only 0xA0 preserving the offset) must ride a reset_required = false
    # frame, not a full_refresh keyframe (#2667 coverage note).
    win1 = window(window_id: 1, rows: rows, top: 0, epoch: 1, full_refresh: false, cursor_row: 0)
    win2 = window(window_id: 1, rows: rows, top: 0, epoch: 1, full_refresh: false, cursor_row: 3)

    transcript(
      "cursor_only_overlay_delta",
      "store",
      %{swift: true, go: true},
      "A 0xA0 overlay delta moves the cursor without touching the retained row set or the committed anchor.",
      [
        frame(@op_window_content, "keyframe", WindowEncoder.encode_window_content(win1), %{
          "store_present" => true,
          "rows" => rows_expect(rows),
          "cursor_row" => 0
        }),
        # Inject a live offset first so offset_discarded => false is a real
        # assertion that a cursor-only 0xA0 delta PRESERVED the offset, not a
        # trivial pass on a window that never had one (#2667 coverage note).
        inject_offset(1, 2, 0),
        frame(
          @op_overlay_delta,
          "cursor-only overlay delta",
          WindowEncoder.encode_overlay_delta(win2),
          %{
            "store_present" => true,
            "rows" => rows_expect(rows),
            "anchor" => anchor(win1),
            "cursor_row" => 3,
            "offset_discarded" => discarded?(scroll(win1), scroll(win2))
          }
        )
      ]
    )
  end

  @spec layout_generation_full_replace() :: transcript()
  defp layout_generation_full_replace do
    rows1 = rows_for(0, 5)

    win1 =
      window(window_id: 1, rows: rows1, top: 0, epoch: 1, full_refresh: true, content_width: 40)

    # A width change alters layout_generation, so the anchor key mismatches and the
    # frontend must replace content and discard any local offset.
    rows2 = for i <- 0..4, do: row(i, "rewrapped #{i}")

    win2 =
      window(window_id: 1, rows: rows2, top: 0, epoch: 1, full_refresh: false, content_width: 64)

    transcript(
      "layout_generation_full_replace",
      "store",
      %{swift: true, go: true},
      "A layout_generation change (width/wrap) mismatches the offset-transform anchor key, so the frontend discards its local offset and fully replaces the resident rows.",
      [
        frame(
          @op_window_content,
          "keyframe (width 40)",
          WindowEncoder.encode_window_content(win1),
          %{
            "store_present" => true,
            "rows" => rows_expect(rows1)
          }
        ),
        inject_offset(1, 4, 0),
        frame(
          @op_window_content,
          "keyframe (width 64, new layout_generation)",
          WindowEncoder.encode_window_content(win2),
          %{
            "store_present" => true,
            "rows" => rows_expect(rows2),
            "anchor" => anchor(win2),
            "offset_discarded" => discarded?(scroll(win1), scroll(win2))
          }
        )
      ]
    )
  end

  @spec reset_required_discard() :: transcript()
  defp reset_required_discard do
    rows1 = rows_for(0, 5)
    win1 = window(window_id: 1, rows: rows1, top: 0, epoch: 1, full_refresh: false, scroll_seq: 2)

    win2 =
      window(
        window_id: 1,
        rows: rows_for(0, 5),
        top: 0,
        epoch: 1,
        full_refresh: true,
        scroll_seq: 2
      )

    transcript(
      "reset_required_discard",
      "store",
      %{swift: true, go: true},
      "A frame with reset_required (full_refresh) forces the frontend to discard any local offset before adopting the new anchor.",
      [
        frame(
          @op_window_content,
          "non-reset keyframe",
          WindowEncoder.encode_window_content(win1),
          %{
            "store_present" => true
          }
        ),
        inject_offset(1, 3, 0),
        frame(
          @op_window_content,
          "reset_required keyframe",
          WindowEncoder.encode_window_content(win2),
          %{
            "store_present" => true,
            "offset_discarded" => true
          }
        )
      ]
    )
  end

  # ── Input-resolution transcripts (AC2) ────────────────────────────────────

  @spec drag_selection_active_offset() :: transcript()
  defp drag_selection_active_offset do
    rows = rows_for(40, 10)

    win =
      window(window_id: 1, rows: rows, top: 40, epoch: 1, full_refresh: true, content_height: 10)

    row_offset = 3
    pointer_row = 2

    transcript(
      "drag_selection_active_offset",
      "input",
      %{swift: true, go: true},
      "With a nonzero local scroll offset active, a drag pointer at a content-relative row is normalized through the presentation offset transform before it is sent to the BEAM, so it maps to the visually-correct buffer line.",
      [
        frame(
          @op_window_content,
          "keyframe anchored at line 40",
          WindowEncoder.encode_window_content(win),
          %{
            "store_present" => true,
            "anchor" => anchor(win)
          }
        ),
        inject_offset(1, row_offset, 0),
        %{
          "kind" => "pointer",
          "window_id" => 1,
          "pointer_row" => pointer_row,
          "pointer_col" => 3,
          "expect" => %{
            # anchor_top + clamp(pointer_row + row_offset, 0, height-1)
            "normalized_buffer_line" => 40 + pointer_row + row_offset
          }
        }
      ]
    )
  end

  @spec hml_after_scroll_report() :: transcript()
  defp hml_after_scroll_report do
    rows = rows_for(10, 10)

    win1 =
      window(
        window_id: 1,
        rows: rows,
        top: 10,
        epoch: 1,
        full_refresh: true,
        scroll_seq: 3,
        cursor_row: 0
      )

    # After a free-scroll report, the BEAM commits the same top it was told (an
    # echo: scroll_seq does NOT advance) and resolves H/M/L against that reported
    # top, moving only the cursor. The frontend must keep its local offset (no
    # re-anchor storm) because the committed top equals the reported top.
    win2 =
      window(
        window_id: 1,
        rows: rows,
        top: 10,
        epoch: 1,
        full_refresh: false,
        scroll_seq: 3,
        cursor_row: 5
      )

    {viewport_delta, true} = WindowEncoder.encode_viewport_delta(win2, hashes(rows))

    transcript(
      "hml_after_scroll_report",
      "input",
      %{swift: true, go: true},
      "An H/M/L command that resolves against a just-reported scroll top commits an echo frame (same anchor, same scroll_seq) that moves only the cursor; the frontend keeps its local offset instead of re-anchoring every wheel/trackpad frame.",
      [
        frame(
          @op_window_content,
          "keyframe anchored at line 10",
          WindowEncoder.encode_window_content(win1),
          %{
            "store_present" => true,
            "cursor_row" => 0
          }
        ),
        inject_offset(1, 2, 0),
        frame(@op_viewport_delta, "H/M/L echo commit (cursor to row 5)", viewport_delta, %{
          "store_present" => true,
          "anchor" => anchor(win2),
          "cursor_row" => 5,
          "offset_discarded" => discarded?(scroll(win1), scroll(win2))
        })
      ]
    )
  end

  @spec scroll_seq_strictly_newer_discard() :: transcript()
  defp scroll_seq_strictly_newer_discard do
    rows = rows_for(0, 10)
    win1 = window(window_id: 1, rows: rows, top: 0, epoch: 1, full_refresh: true, scroll_seq: 5)

    # Identical anchor key (same epoch/layout/top/left) but a strictly newer
    # scroll_seq: a BEAM-initiated jump raced a local scroll and coincidentally
    # landed on the same top. Only the sequence increase disambiguates it.
    win2 = window(window_id: 1, rows: rows, top: 0, epoch: 1, full_refresh: false, scroll_seq: 6)
    {viewport_delta, true} = WindowEncoder.encode_viewport_delta(win2, hashes(rows))

    transcript(
      "scroll_seq_strictly_newer_discard",
      "input",
      %{swift: true, go: true},
      "A strictly-newer scroll_seq with an identical anchor key forces a local-offset discard, disambiguating a BEAM jump that landed on the same top from a routine echo.",
      [
        frame(
          @op_window_content,
          "keyframe (scroll_seq 5)",
          WindowEncoder.encode_window_content(win1),
          %{
            "store_present" => true
          }
        ),
        inject_offset(1, 3, 0),
        frame(@op_viewport_delta, "same anchor, scroll_seq 6", viewport_delta, %{
          "store_present" => true,
          "anchor" => anchor(win2),
          "offset_discarded" => discarded?(scroll(win1), scroll(win2))
        })
      ]
    )
  end

  @spec same_top_jump_discards() :: transcript()
  defp same_top_jump_discards do
    rows = rows_for(0, 10)
    win1 = window(window_id: 1, rows: rows, top: 0, epoch: 1, full_refresh: true, scroll_seq: 5)

    # A jump that lands on exactly the previous/echoed top. The settle-time top
    # comparison cannot see it, but the authoritative-scroll marker set by the jump
    # command bumps scroll_seq anyway (#2652), so the frame carries scroll_seq 6 and
    # the frontend discards its local offset. The anchor key is byte-identical to
    # win1's; only the sequence increase disambiguates the jump from an echo.
    win2 = window(window_id: 1, rows: rows, top: 0, epoch: 1, full_refresh: false, scroll_seq: 6)
    {viewport_delta, true} = WindowEncoder.encode_viewport_delta(win2, hashes(rows))

    transcript(
      "same_top_jump_discards",
      "input",
      %{swift: true, go: true},
      "An authoritative viewport jump (zz already centered, a search hit already on screen) lands on exactly the previous top. The explicit authoritative-scroll marker bumps scroll_seq even with an unchanged anchor, so the frontend discards its local offset (#2652).",
      [
        frame(
          @op_window_content,
          "keyframe (scroll_seq 5)",
          WindowEncoder.encode_window_content(win1),
          %{
            "store_present" => true
          }
        ),
        inject_offset(1, 3, 0),
        frame(
          @op_viewport_delta,
          "same anchor, scroll_seq 6 (authoritative marker bump)",
          viewport_delta,
          %{
            "store_present" => true,
            "anchor" => anchor(win2),
            "offset_discarded" => discarded?(scroll(win1), scroll(win2))
          }
        )
      ]
    )
  end

  @spec wheel_momentum_during_ctrl_d() :: transcript()
  defp wheel_momentum_during_ctrl_d do
    rows = rows_for(8, 10)
    win1 = window(window_id: 1, rows: rows, top: 8, epoch: 1, full_refresh: true, scroll_seq: 5)

    # Momentum keeps feeding wheel deltas (inject a growing offset) while ctrl-d's
    # authoritative anchor lands. In the residence config the committed top equals
    # the reported top, so only the scroll_seq bump forces the discard. Two rounds
    # model momentum still firing AFTER the first authoritative anchor.
    win2 = window(window_id: 1, rows: rows, top: 8, epoch: 1, full_refresh: false, scroll_seq: 6)
    {delta1, true} = WindowEncoder.encode_viewport_delta(win2, hashes(rows))
    win3 = window(window_id: 1, rows: rows, top: 8, epoch: 1, full_refresh: false, scroll_seq: 7)
    {delta2, true} = WindowEncoder.encode_viewport_delta(win3, hashes(rows))

    transcript(
      "wheel_momentum_during_ctrl_d",
      "input",
      %{swift: true, go: true},
      "Wheel momentum keeps feeding local-offset updates while ctrl-d's authoritative anchor lands on the same top; each authoritative commit bumps scroll_seq, which must discard the leftover momentum offset even though momentum is still active.",
      [
        frame(
          @op_window_content,
          "keyframe (scroll_seq 5)",
          WindowEncoder.encode_window_content(win1),
          %{
            "store_present" => true
          }
        ),
        inject_offset(1, 6, 0),
        frame(@op_viewport_delta, "first ctrl-d authoritative anchor (scroll_seq 6)", delta1, %{
          "store_present" => true,
          "offset_discarded" => discarded?(scroll(win1), scroll(win2))
        }),
        inject_offset(1, 2, 0),
        frame(
          @op_viewport_delta,
          "momentum continues; second authoritative anchor (scroll_seq 7)",
          delta2,
          %{
            "store_present" => true,
            "offset_discarded" => discarded?(scroll(win2), scroll(win3))
          }
        )
      ]
    )
  end

  # ── Resident agent-transcript transcripts (0x86, #2654 slice 5) ───────────
  #
  # A NEW transcript family. The frames are produced by the real
  # AgentTranscriptEncoder (so an encoder change regenerates the corpus and drift
  # is caught) and folded through the frontends' real resident-store apply
  # functions (Swift AgentChatState.applyTranscript, Go residentTranscript.apply).
  #
  # Two things are asserted per transcript:
  #
  #   * `transcript_frame.expect.transcript` — the resident store's {epoch, count,
  #     truncated, message_ids} after applying the frame. This is the SHARED
  #     parity core: both frontends decode the same encoder bytes and must produce
  #     the identical id list. The BEAM oracle re-decodes the same bytes as a
  #     self-check (test/conformance/agent_transcript_corpus_test.exs).
  #
  #   * Position preservation, per-frontend because the offset models differ. Swift
  #     is SwiftUI-native (ForEach id stability preserves the scroll), so its runner
  #     asserts an anchor id stays at a store index (`transcript_assert.swift`). Go
  #     owns a top-anchored scroll offset in the store, so its runner drives the
  #     pure scrollBy/resolveScroll functions and asserts the offset + pin state
  #     (`transcript_scroll.go`, `transcript_assert.go`). Both frontends run every
  #     chat transcript; there are no go_skip entries.

  @spec append_while_scrolled_up() :: transcript()
  defp append_while_scrolled_up do
    m1 = for i <- 1..8, do: chat_msg(i, "message #{i}")
    {f1, caches1} = AgentTranscriptEncoder.encode(chat_model(1, m1), Caches.new())

    m2 = Enum.concat(m1, [chat_msg(9, "message 9")])
    {f2, _caches2} = AgentTranscriptEncoder.encode(chat_model(1, m2), caches1)

    chat_transcript(
      "append_while_scrolled_up",
      "A resident append at the bottom while the reader is scrolled up preserves the reading position: the id at the reader's anchor stays at the same store index (Swift SwiftUI id stability), and the Go top-anchored resolveScroll offset is unchanged by the bottom growth.",
      [
        transcript_frame(
          "full_replace, 8 messages",
          f1,
          chat_expect(1, false, Enum.to_list(1..8))
        ),
        transcript_scroll("reader scrolls up 4 rows, leaving the bottom", -4, %{
          "max_top" => 6,
          "expect_top_offset" => 2,
          "expect_pinned" => false,
          "expect_pin_transition" => "scrolled_away"
        }),
        transcript_frame(
          "append message 9 at the bottom",
          f2,
          chat_expect(1, false, Enum.to_list(1..9))
        ),
        transcript_assert(
          "reading position preserved across the append",
          %{"anchor_index" => 2, "anchor_id" => 3},
          %{"max_top" => 7, "expect_top_offset" => 2, "expect_pinned" => false}
        )
      ]
    )
  end

  @spec pin_to_bottom_resume() :: transcript()
  defp pin_to_bottom_resume do
    m1 = for i <- 1..6, do: chat_msg(i, "msg #{i}")
    {f1, caches1} = AgentTranscriptEncoder.encode(chat_model(1, m1), Caches.new())

    m2 = Enum.concat(m1, [chat_msg(7, "msg 7")])
    {f2, _caches2} = AgentTranscriptEncoder.encode(chat_model(1, m2), caches1)

    chat_transcript(
      "pin_to_bottom_resume",
      "A reader scrolls up (unpins), then scrolls back to the bottom (re-pins, emitting the returned-to-bottom edge). A following append is then followed: Go stays pinned; the Swift store's newest message is at the tail the bottom-anchored view follows.",
      [
        transcript_frame(
          "full_replace, 6 messages",
          f1,
          chat_expect(1, false, Enum.to_list(1..6))
        ),
        transcript_scroll("reader scrolls up 3 rows", -3, %{
          "max_top" => 4,
          "expect_top_offset" => 1,
          "expect_pinned" => false,
          "expect_pin_transition" => "scrolled_away"
        }),
        transcript_scroll("reader scrolls back to the bottom", 3, %{
          "max_top" => 4,
          "expect_top_offset" => 4,
          "expect_pinned" => true,
          "expect_pin_transition" => "returned"
        }),
        transcript_frame(
          "append message 7 while pinned",
          f2,
          chat_expect(1, false, Enum.to_list(1..7))
        ),
        transcript_assert(
          "pinned view follows the new bottom message",
          %{"anchor_index" => 6, "anchor_id" => 7},
          %{"max_top" => 5, "expect_pinned" => true}
        )
      ]
    )
  end

  @spec session_switch_full_replace() :: transcript()
  defp session_switch_full_replace do
    m1 = for i <- 1..5, do: chat_msg(i, "old #{i}")
    {f1, caches1} = AgentTranscriptEncoder.encode(chat_model(1, m1), Caches.new())

    # A new session: a different epoch and a disjoint id space. The epoch flip
    # forces a full_replace regardless of message content.
    m2 = for i <- 0..3, do: chat_msg(100 + i, "new #{i}")
    {f2, _caches2} = AgentTranscriptEncoder.encode(chat_model(2, m2), caches1)

    chat_transcript(
      "session_switch_full_replace",
      "A session switch arrives as a full_replace at a new epoch. It resets the resident store to the new session's messages and re-pins to the bottom, discarding any prior local scroll offset.",
      [
        transcript_frame(
          "full_replace, session 1 (epoch 1)",
          f1,
          chat_expect(1, false, Enum.to_list(1..5))
        ),
        transcript_scroll("reader scrolls up 2 rows in session 1", -2, %{
          "max_top" => 3,
          "expect_top_offset" => 1,
          "expect_pinned" => false,
          "expect_pin_transition" => "scrolled_away"
        }),
        transcript_frame(
          "session switch: full_replace at epoch 2",
          f2,
          chat_expect(2, false, [100, 101, 102, 103])
        ),
        transcript_assert(
          "session switch re-pins to the bottom and resets the offset",
          %{"anchor_index" => 0, "anchor_id" => 100},
          %{"max_top" => 2, "expect_top_offset" => 0, "expect_pinned" => true}
        )
      ]
    )
  end

  @spec trim_front_eviction_midstream() :: transcript()
  defp trim_front_eviction_midstream do
    # Each entry is 8 (id+len) + 200 (body) = 208 wire bytes; four fit under the
    # 1000-byte cap, a fifth does not. Growing to six messages evicts the two
    # oldest from the semantic resident suffix and marks the stream truncated.
    m1 = for i <- 1..4, do: sized_chat_msg(i, 200)
    {f1, caches1} = AgentTranscriptEncoder.encode(chat_model(1, m1, 1_000), Caches.new())

    m2 = for i <- 1..6, do: sized_chat_msg(i, 200)
    {f2, _caches2} = AgentTranscriptEncoder.encode(chat_model(1, m2, 1_000), caches1)

    chat_transcript(
      "trim_front_eviction_midstream",
      "Streaming past the resident byte cap evicts the oldest messages from the store front (append trim_front) and flags the stream truncated, instead of degrading to a full_replace per frame. Both frontends drop the trimmed prefix and keep the most-recent contiguous suffix.",
      [
        transcript_frame(
          "full_replace, 4 messages under the cap",
          f1,
          chat_expect(1, false, [1, 2, 3, 4])
        ),
        transcript_frame(
          "append past the cap: front eviction (trim_front) + truncated",
          f2,
          chat_expect(1, true, [3, 4, 5, 6])
        )
      ]
    )
  end

  @spec epoch_flip_midstream() :: transcript()
  defp epoch_flip_midstream do
    m1 = [chat_msg(1, "a"), chat_msg(2, "b"), chat_msg(3, "c")]
    {f1, caches1} = AgentTranscriptEncoder.encode(chat_model(5, m1), Caches.new())

    m2 = Enum.concat(m1, [chat_msg(4, "d")])
    {f2, caches2} = AgentTranscriptEncoder.encode(chat_model(5, m2), caches1)

    # Same messages, new epoch: the epoch token flip alone forces a full_replace.
    {f3, _caches3} = AgentTranscriptEncoder.encode(chat_model(6, m2), caches2)

    chat_transcript(
      "epoch_flip_midstream",
      "An in-epoch append followed by an epoch flip. The append stays incremental; the epoch flip forces a full_replace even though the messages are unchanged, and both frontends adopt the new epoch.",
      [
        transcript_frame("full_replace at epoch 5", f1, chat_expect(5, false, [1, 2, 3])),
        transcript_frame(
          "append message 4 within epoch 5",
          f2,
          chat_expect(5, false, [1, 2, 3, 4])
        ),
        transcript_frame(
          "epoch flip to 6 forces a full_replace",
          f3,
          chat_expect(6, false, [1, 2, 3, 4])
        )
      ]
    )
  end

  @spec streaming_tail_patch() :: transcript()
  defp streaming_tail_patch do
    m1 = [chat_msg(1, "question"), {2, {:assistant, "par"}}]
    {f1, caches1} = AgentTranscriptEncoder.encode(chat_model(1, m1), Caches.new())

    # The streaming assistant message (id 2) grows in place: same id, new content.
    m2 = [chat_msg(1, "question"), {2, {:assistant, "partial answer"}}]
    {f2, _caches2} = AgentTranscriptEncoder.encode(chat_model(1, m2), caches1)

    chat_transcript(
      "streaming_tail_patch",
      "The streaming last message is patched in place by id (same id, new content). The store count stays 2 with ids [1, 2]; a frontend that appended instead of upserting by id would show a duplicate, which the count assertion catches.",
      [
        transcript_frame(
          "full_replace, user + streaming assistant",
          f1,
          chat_expect(1, false, [1, 2])
        ),
        transcript_frame(
          "streaming tail patch of message 2 (same id, new content)",
          f2,
          chat_expect(1, false, [1, 2])
        )
      ]
    )
  end

  # ── Chat builders + step shaping ──────────────────────────────────────────

  @spec chat_model(non_neg_integer(), [AgentChat.message()], pos_integer() | nil) :: AgentChat.t()
  defp chat_model(epoch, messages, max_bytes \\ nil)

  defp chat_model(epoch, messages, nil) do
    %AgentChat{visible?: true, resident_messages: messages, transcript_epoch: epoch}
  end

  defp chat_model(epoch, messages, max_bytes) do
    {resident_messages, resident_truncated?} =
      AgentChat.resident_suffix(messages, max_bytes, &AgentChatMessageCodec.resident_entry_size/1)

    %AgentChat{
      visible?: true,
      resident_messages: resident_messages,
      resident_truncated?: resident_truncated?,
      transcript_epoch: epoch
    }
  end

  @spec chat_msg(pos_integer(), String.t()) :: AgentChat.message()
  defp chat_msg(id, text), do: {id, {:assistant, text}}

  # A user message whose encoded body is exactly `body_bytes` (>= 5): the body is
  # 0x01 + len:u32 + text, so the text length is body_bytes - 5. Used to hit the
  # resident byte cap deterministically.
  @spec sized_chat_msg(pos_integer(), pos_integer()) :: AgentChat.message()
  defp sized_chat_msg(id, body_bytes) when body_bytes >= 5 do
    {id, {:user, String.duplicate("x", body_bytes - 5)}}
  end

  @spec chat_expect(non_neg_integer(), boolean(), [pos_integer()]) :: map()
  defp chat_expect(epoch, truncated?, ids) do
    %{
      "epoch" => epoch,
      "count" => length(ids),
      "truncated" => truncated?,
      "message_ids" => ids
    }
  end

  @spec transcript_frame(String.t(), binary(), map()) :: map()
  defp transcript_frame(note, frame, expect_transcript) do
    %{
      "kind" => "transcript_frame",
      "opcode" => @op_gui_agent_transcript,
      "note" => note,
      "payload_base64" => Base.encode64(frame),
      "expect" => %{"transcript" => expect_transcript}
    }
  end

  @spec transcript_scroll(String.t(), integer(), map()) :: map()
  defp transcript_scroll(note, rows, go) do
    %{"kind" => "transcript_scroll", "note" => note, "rows" => rows, "go" => go}
  end

  @spec transcript_assert(String.t(), map(), map()) :: map()
  defp transcript_assert(note, swift, go) do
    %{"kind" => "transcript_assert", "note" => note, "swift" => swift, "go" => go}
  end

  @spec chat_transcript(String.t(), String.t(), [map()]) :: transcript()
  defp chat_transcript(name, description, steps) do
    transcript(name, "chat", %{swift: true, go: true}, description, steps)
  end

  # ── Reconciliation rule (mirrors docs/GUI_PROTOCOL.md) ────────────────────

  # These clauses mirror the documented offset-transform reconciliation rule so
  # the expected offset_discarded matches the real frontend decision functions
  # (Swift shouldResetScrollPresentation / Go localPresentation.reconcileScroll).
  @spec discarded?(sp(), sp()) :: boolean()
  defp discarded?(_prev, %ScrollPresentation{reset_required: true}), do: true

  defp discarded?(%ScrollPresentation{scroll_seq: p}, %ScrollPresentation{scroll_seq: n})
       when n > p,
       do: true

  defp discarded?(%ScrollPresentation{} = prev, %ScrollPresentation{} = next),
    do: not same_anchor_key?(prev, next)

  @spec same_anchor_key?(sp(), sp()) :: boolean()
  defp same_anchor_key?(%ScrollPresentation{} = a, %ScrollPresentation{} = b) do
    a.content_epoch == b.content_epoch and a.layout_generation == b.layout_generation and
      a.anchor_top == b.anchor_top and a.anchor_left == b.anchor_left
  end

  # ── Render-model builders ─────────────────────────────────────────────────

  @spec window(keyword()) :: RW.t()
  defp window(opts) do
    wid = Keyword.fetch!(opts, :window_id)
    rows = Keyword.fetch!(opts, :rows)
    top = Keyword.get(opts, :top, 0)
    width = Keyword.get(opts, :content_width, 40)
    height = Keyword.get(opts, :content_height, 10)

    %RW{
      window_id: wid,
      content_kind: :buffer,
      rect: {0, 0, width, height},
      rows: rows,
      cursor_row: Keyword.get(opts, :cursor_row, 0),
      cursor_col: Keyword.get(opts, :cursor_col, 0),
      cursor_shape: :block,
      content_epoch: Keyword.get(opts, :epoch, 1),
      full_refresh: Keyword.get(opts, :full_refresh, true),
      contiguous_rows: true,
      scroll_seq: Keyword.get(opts, :scroll_seq, 0),
      geometry: geometry(wid, top, width, height)
    }
  end

  @spec geometry(non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          PaneGeometry.t()
  defp geometry(wid, top, width, height) do
    gutter = 5

    %PaneGeometry{
      window_id: wid,
      total_rect: {0, 0, width + gutter, height},
      content_rect: {0, 0, width, height},
      text_rect: {0, gutter, width, height},
      gutter_rect: {0, 0, gutter, height},
      clip_rect: {0, 0, width, height},
      viewport: %Viewport{
        top: top,
        left: 0,
        rows: height,
        cols: width,
        total_lines: 1000,
        visual_row_offset: 0,
        total_visual_rows: 1000
      },
      gutter_metrics: %GutterMetrics{line_number_width: 4, sign_col_width: 1},
      hit_regions: []
    }
  end

  @spec rows_for(non_neg_integer(), non_neg_integer()) :: [Row.t()]
  defp rows_for(start, count) do
    for i <- 0..(count - 1), do: row(start + i, "line #{start + i}")
  end

  @spec row(non_neg_integer(), String.t()) :: Row.t()
  defp row(buf_line, text) do
    %Row{
      row_id: Row.stable_id(:normal, buf_line),
      row_type: :normal,
      buf_line: buf_line,
      visual_index: buf_line,
      text: text,
      spans: [],
      content_hash: Row.compute_hash(text, [])
    }
  end

  @spec hashes([Row.t()]) :: %{non_neg_integer() => non_neg_integer()}
  defp hashes(rows), do: Map.new(rows, fn %Row{} = r -> {r.row_id, r.content_hash} end)

  @spec scroll(RW.t()) :: sp()
  defp scroll(%RW{} = win), do: ScrollPresentation.from_window(win)

  @spec anchor(RW.t()) :: %{String.t() => non_neg_integer()}
  defp anchor(%RW{} = win) do
    %ScrollPresentation{anchor_top: top, anchor_left: left} = scroll(win)
    %{"top" => top, "left" => left}
  end

  # ── Step + transcript shaping ─────────────────────────────────────────────

  @spec frame(non_neg_integer(), String.t(), binary(), map()) :: map()
  defp frame(opcode, note, payload, expect) do
    %{
      "kind" => "frame",
      "opcode" => opcode,
      "note" => note,
      "payload_base64" => Base.encode64(payload),
      "expect" => expect
    }
  end

  @spec inject_offset(non_neg_integer(), integer(), integer()) :: map()
  defp inject_offset(window_id, row_offset, col_offset) do
    %{
      "kind" => "inject_offset",
      "window_id" => window_id,
      "row_offset" => row_offset,
      "col_offset" => col_offset
    }
  end

  @spec rows_expect([Row.t()]) :: [map()]
  defp rows_expect(rows) do
    Enum.map(rows, fn %Row{} = r ->
      %{
        "row_id" => Integer.to_string(r.row_id),
        "content_hash" => r.content_hash,
        "buf_line" => r.buf_line
      }
    end)
  end

  @spec transcript(String.t(), String.t(), map(), String.t(), [map()]) :: transcript()
  defp transcript(name, category, frontends, description, steps) do
    %{
      "name" => name,
      "category" => category,
      "description" => description,
      "frontends" => %{
        "swift" => Map.get(frontends, :swift, true),
        "go" => Map.get(frontends, :go, true),
        "go_skip_reason" => Map.get(frontends, :go_skip_reason)
      },
      "steps" => steps
    }
  end

  @spec write_transcript(transcript()) :: :ok
  defp write_transcript(%{"name" => name, "category" => category} = transcript) do
    path = Path.join([@corpus_dir, category, name <> ".json"])
    File.write!(path, JSON.encode!(transcript) <> "\n")
    :ok
  end

  @spec write_index([transcript()]) :: :ok
  defp write_index(transcripts) do
    entries =
      Enum.map(transcripts, fn t ->
        %{
          "name" => t["name"],
          "category" => t["category"],
          "file" => Path.join(t["category"], t["name"] <> ".json"),
          "swift" => t["frontends"]["swift"],
          "go" => t["frontends"]["go"],
          "go_skip_reason" => t["frontends"]["go_skip_reason"]
        }
      end)

    index = %{"version" => 1, "transcripts" => entries}
    File.write!(Path.join(@corpus_dir, "index.json"), JSON.encode!(index) <> "\n")
    :ok
  end
end
