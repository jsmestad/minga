defmodule Mix.Tasks.Conformance.PixelScenarios do
  @moduledoc "Production-framed, model-derived Metal composition evidence for #3520."

  alias MingaEditor.Renderer.Server
  alias MingaEditor.Renderer.Submission
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.UI.Theme
  alias Mix.Tasks.Conformance.RecoveryDriver

  @neutral 0x202020
  @red 0xE01010
  @blue 0x1010E0
  @rows 6
  @cols 40

  @doc "Builds three pixel transcripts using the actual Editor/Renderer/Manager driver."
  @spec build_all() :: [map()]
  def build_all do
    [background_fill(), spaced_rows(), no_stale_glyphs_after_local_scroll()]
  end

  defp background_fill do
    RecoveryDriver.with_driver(options(blank_content()), fn driver ->
      resize = RecoveryDriver.resize(driver, @rows, @cols)
      setup = RecoveryDriver.render(driver, 1)
      ack_setup = RecoveryDriver.acknowledge(driver, setup)
      frame = RecoveryDriver.render(driver, 2)
      rect = text_rect(frame)

      edge =
        region(
          "background reaches frame edge",
          [
            rect["row"] + rect["height"] - 0.25,
            rect["col"] + rect["width"] - 0.25,
            0.25,
            0.25
          ],
          "color"
        )

      transcript(
        "pixels_background_fill",
        "Composition evidence for fix(macos): editor background fills to the frame edge, 6ab625b2c (#2687). The explicit fill and production clear now share defaultBg; removing only the fill is a documented surviving mutation, not a claimed historical-fix kill.",
        [
          resize,
          setup,
          ack_setup,
          pixels(frame, [edge, text_region(frame, 3, "blank carried row", "empty")])
        ]
      )
    end)
  end

  defp spaced_rows do
    content =
      Enum.map_join(0..63, "\n", fn row ->
        if row == 3, do: String.duplicate("M", 24), else: ""
      end)

    RecoveryDriver.with_driver(options(content, 2.0), fn driver ->
      resize = RecoveryDriver.resize(driver, @rows, @cols)
      setup = RecoveryDriver.render(driver, 1)
      ack_setup = RecoveryDriver.acknowledge(driver, setup)
      frame = RecoveryDriver.render(driver, 2)

      transcript(
        "pixels_spaced_rows",
        "Spaced-row Metal composition accompanying fix(macos): IME and accessibility row geometry uses spaced cell height, 966352a7c (#2674). That historical fix is view-owned: ConformanceSpacedInputGeometry additionally exercises production EditorNSView; direct Metal pixels alone cannot prove its mutation.",
        [
          resize,
          setup,
          ack_setup,
          pixels(frame, [
            text_region(frame, 3, "glyphs follow doubled row spacing", "occupied"),
            text_region(frame, 2, "preceding spaced row remains empty", "empty")
          ])
        ]
      )
    end)
  end

  defp no_stale_glyphs_after_local_scroll do
    content =
      Enum.map_join(0..63, "\n", fn row ->
        if row == 3, do: String.duplicate("M", 24), else: ""
      end)

    RecoveryDriver.with_driver(options(content), fn driver ->
      resize = RecoveryDriver.resize(driver, @rows, @cols)
      setup = RecoveryDriver.render(driver, 1)
      ack_setup = RecoveryDriver.acknowledge(driver, setup)
      first = RecoveryDriver.render(driver, 2)
      ack_first = RecoveryDriver.acknowledge(driver, first)
      scrolled = RecoveryDriver.render(driver, 3)
      ack_scrolled = RecoveryDriver.acknowledge(driver, scrolled)
      state = :sys.get_state(driver.editor)
      :ok = Minga.Buffer.replace_content(state.workspace.buffers.active, blank_content())
      state = :sys.get_state(driver.editor)

      intent =
        state |> Intent.from_editor_state(4) |> Intent.for_frontend(driver.manager, driver.opts)

      {:ok, _receipt} = Server.reset_keyframe_sync(driver.renderer, Submission.full(intent), 4)
      reset = RecoveryDriver.capture(driver)

      transcript(
        "pixels_no_stale_glyphs_after_local_scroll",
        "Local-scroll composition accompanying fix(macos): reconcile local scroll with drawn snapshot, 559792551 (#3397). Draw glyphs, inject a one-row local offset and draw it, then commit a real reset keyframe with blank rows: both old glyph regions must be empty. Production EditorNSView captured-commit publication is separately checked by conformanceScrollPublicationUsesCapturedCommit; this direct-renderer transcript does not claim to exercise view reconciliation.",
        [
          resize,
          setup,
          ack_setup,
          pixels(first, [text_region(first, 3, "initial glyph row", "occupied")]),
          ack_first,
          %{
            "kind" => "inject_offset",
            "window_id" => window_id(first),
            "row_offset" => 1,
            "col_offset" => 0
          },
          pixels(scrolled, [text_region(scrolled, 2, "locally scrolled glyph row", "occupied")]),
          ack_scrolled,
          pixels(reset, [
            text_region(reset, 2, "no stale scrolled glyphs", "empty"),
            text_region(reset, 3, "no stale original glyphs", "empty")
          ])
        ]
      )
    end)
  end

  defp options(content, spacing \\ 1.2) do
    theme = Theme.get!(:minga_default)

    theme = %{
      theme
      | name: :conformance_pixels,
        editor: %{theme.editor | bg: @neutral, fg: @red, cursorline_bg: @neutral},
        gutter: %{theme.gutter | fg: @blue, current_fg: @blue}
    }

    [content: content, rows: @rows, cols: @cols, theme: theme, line_spacing: spacing]
  end

  defp blank_content, do: Enum.map_join(0..63, "\n", fn _ -> "" end)

  # The oracle decodes the exact encoded model. Region rows and gutter offsets
  # therefore come from the same pane/row carriers, not hand-authored geometry.
  defp text_rect(frame), do: frame["expect"]["pane_rects"] |> hd() |> Map.fetch!("text_rect")
  defp window_id(frame), do: frame["expect"]["pane_rects"] |> hd() |> Map.fetch!("window_id")

  defp text_region(frame, local_row, name, assertion) do
    rect = text_rect(frame)
    true = local_row < rect["height"]
    true = length(frame["expect"]["rows"]) > local_row

    region(
      name,
      [rect["row"] + local_row, rect["col"] + 4, 1, min(rect["width"] - 8, 12)],
      assertion
    )
  end

  defp region(name, cells, assertion) do
    %{
      "region" => name,
      "cells" => cells,
      "assert" => assertion,
      "color" => "0x202020",
      "tolerance" => 0.02
    }
  end

  defp pixels(frame, regions) do
    frame
    |> Map.put("swift_only", true)
    |> Map.update!("expect", &Map.put(&1, "pixels", regions))
  end

  defp transcript(name, description, steps) do
    %{
      "name" => name,
      "category" => "pixels",
      "description" => description,
      "frontends" => %{"swift" => true, "go" => true, "go_skip_reason" => nil},
      "steps" => steps
    }
  end
end
