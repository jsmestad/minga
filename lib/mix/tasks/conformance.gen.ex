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

  alias Minga.Frontend.Adapter.GUI.WindowEncoder
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

  @typep sp :: ScrollPresentation.t()
  @typep transcript :: %{optional(String.t()) => term()}

  @doc "Builds and writes the full conformance corpus."
  @spec run([String.t()]) :: :ok
  def run(_args) do
    File.mkdir_p!(Path.join(@corpus_dir, "store"))
    File.mkdir_p!(Path.join(@corpus_dir, "input"))

    transcripts = build_all()
    Enum.each(transcripts, &write_transcript/1)
    write_index(transcripts)

    Mix.shell().info(
      "conformance.gen: wrote #{length(transcripts)} transcripts to #{@corpus_dir}"
    )

    :ok
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
      same_top_jump_documented_limitation(),
      wheel_momentum_during_ctrl_d()
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
      "An H/M/L command that resolves against a just-reported scroll top commits an echo frame (same anchor, same scroll_seq) that moves only the cursor; the frontend keeps its local offset instead of re-anchoring every margin-riding frame.",
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

  @spec same_top_jump_documented_limitation() :: transcript()
  defp same_top_jump_documented_limitation do
    rows = rows_for(0, 10)
    win1 = window(window_id: 1, rows: rows, top: 0, epoch: 1, full_refresh: true, scroll_seq: 5)

    # A jump that lands on exactly the previous/echoed top with NO scroll_seq bump:
    # the documented current limitation. The frontend cannot tell it apart from an
    # echo, so it does NOT discard. When the future explicit bump_scroll_seq lands
    # at the authoritative jump call sites, this frame carries scroll_seq 6 and the
    # expectation flips to offset_discarded = true.
    win2 = window(window_id: 1, rows: rows, top: 0, epoch: 1, full_refresh: false, scroll_seq: 5)
    {viewport_delta, true} = WindowEncoder.encode_viewport_delta(win2, hashes(rows))

    transcript(
      "same_top_jump_documented_limitation",
      "input",
      %{swift: true, go: true},
      "DOCUMENTED CURRENT LIMITATION: a jump landing on exactly the previous top without a scroll_seq bump is indistinguishable from an echo, so no discard happens. The future explicit bump_scroll_seq at the jump call sites will flip this expectation to offset_discarded = true.",
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
        frame(@op_viewport_delta, "same anchor, same scroll_seq (no bump)", viewport_delta, %{
          "store_present" => true,
          "anchor" => anchor(win2),
          "offset_discarded" => discarded?(scroll(win1), scroll(win2))
        })
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
