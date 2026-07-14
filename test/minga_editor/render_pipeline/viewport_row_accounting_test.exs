defmodule MingaEditor.RenderPipeline.ViewportRowAccountingTest do
  @moduledoc """
  Chain-locking regression for #2693: GUI-reported rows must survive the
  accounting chain (reported rows -> BEAM layout content height -> emitted
  window rows) without losing rows to chrome the frontend renders natively.

  These assertions are deliberately content-facing: they lock the emitted row
  count against the content area the frontend measured, not the internal
  raw->effective derivation steps (which a future frontend-owned row-fit model
  will replace). A phantom chrome reservation would drop an emitted content row
  and fail loudly here regardless of the units the derivation uses.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Scroll

  import MingaEditor.RenderPipeline.TestHelpers

  # Runs scroll + content and returns the flattened window models keyed by id.
  defp emitted_models(state) do
    state = MingaEditor.WindowFocus.remember_active_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    {contents, _cursor, _state} = Content.build_content(state, scrolls)

    models =
      contents
      |> Enum.flat_map(& &1.models)
      |> Map.new(fn model -> {model.window_id, model} end)

    {models, layout}
  end

  defp content_height({_r, _c, _w, h}), do: h

  # The content area is filled when the emitted rows cover every content row.
  # The free-scroll path (#2692) may paint one extra partially-visible remainder
  # row below the last whole row, so "filled to within one spaced row" means the
  # emitted count is the content height, plus at most that one remainder row.
  defp assert_fills_content(model, content_rows) do
    emitted = length(model.rows)

    assert emitted in content_rows..(content_rows + 1),
           "emitted rows (#{emitted}) should fill the #{content_rows}-row content area (plus at most one sub-row remainder)"
  end

  describe "native GUI row accounting (#2693)" do
    test "emitted content rows fill the full reported viewport (no phantom minibuffer row)" do
      # A phantom chrome reservation would make the emitted content one row
      # shorter than the viewport the frontend measured. Check several heights.
      for rows <- [15, 17, 24, 40] do
        state = gui_state(rows: rows, cols: 108, content: long_content(rows * 3))
        {models, layout} = emitted_models(state)

        [model] = Map.values(models)

        assert content_height(model.rect) == rows,
               "window content height should equal the full viewport (#{rows}), got #{content_height(model.rect)}"

        assert_fills_content(model, rows)

        # The editor area itself claims the whole grid: the gap below the last
        # content row is zero grid rows (the sub-row pixel remainder that #2692
        # paints is strictly < one spaced row and lives below the grid).
        assert content_height(layout.editor_area) == rows
      end
    end

    test "capability gate: terminal frontends still reserve the minibuffer row" do
      # The TUI's reported rows are the full terminal grid, so the minibuffer
      # genuinely consumes the last row. The gate must keep that reservation so
      # the TUI stays byte-identical; only native GUI reclaims the row.
      rows = 24
      base = gui_state(rows: rows, cols: 108, content: long_content(rows * 3))

      tui_state = %{
        base
        | frontend:
            MingaEditor.State.Frontend.accept_capabilities(
              base.frontend,
              %Capabilities{frontend_type: :tui, semantic_ui: true}
            )
      }

      {models, layout} = emitted_models(tui_state)
      [model] = Map.values(models)

      assert content_height(layout.editor_area) == rows - 1
      assert content_height(model.rect) == rows - 1
      assert_fills_content(model, rows - 1)
    end

    test "line spacing feeds the row count exactly once, then fills the viewport" do
      # Reconcile the reported ledger: a 21-cell-tall window at spacing 1.2 floors
      # once on the frontend to 17 rows-that-fit, and the BEAM emits all 17 as
      # content (the #2693 report saw 17 but only ~16 rendered because of the
      # phantom reservation). Per ADR-0001 the single floor lives on the frontend
      # (floor(cells / spacing)); the BEAM performs no spacing arithmetic and lays
      # out in exactly the rows it is given.
      raw_rows = 21

      for {spacing, expected} <- [{1.0, 21}, {1.2, 17}] do
        effective = floor(raw_rows / spacing)

        assert effective == expected,
               "frontend row-fit floor(#{raw_rows} / #{spacing}) should be #{expected}"

        state = gui_state(rows: effective, cols: 108, content: long_content(effective * 3))
        {models, _layout} = emitted_models(state)
        [model] = Map.values(models)

        # Emitted rows equal the reported viewport rows: spacing applied once,
        # no phantom chrome deduction on top.
        assert content_height(model.rect) == effective
        assert_fills_content(model, effective)
      end
    end

    test "splits: each pane fills its share with no per-pane phantom reservation" do
      rows = 40

      # Vertical split: both panes span the full editor height (no horizontal
      # separator), so each pane's content height equals the full viewport.
      vstate =
        gui_state(rows: rows, cols: 120, content: long_content(rows * 3))
        |> split_active_window(:vertical)

      {vmodels, _} = emitted_models(vstate)
      assert map_size(vmodels) == 2

      for {_id, model} <- vmodels do
        assert content_height(model.rect) == rows
        assert_fills_content(model, rows)
      end

      # Horizontal split: the two panes plus the 1-row separator tile the full
      # viewport, so the pane heights sum to the full grid minus the separator.
      hstate =
        gui_state(rows: rows, cols: 120, content: long_content(rows * 3))
        |> split_active_window(:horizontal)

      {hmodels, hlayout} = emitted_models(hstate)
      assert map_size(hmodels) == 2

      total_pane_rows =
        hmodels |> Map.values() |> Enum.map(&content_height(&1.rect)) |> Enum.sum()

      separator_rows = length(hlayout.horizontal_separators)
      assert total_pane_rows + separator_rows == rows
    end
  end

  # Splits the active window using the workspace Windows API so the layout sees a
  # real split tree. Returns the updated state.
  defp split_active_window(state, direction) do
    windows = state.workspace.windows
    active = windows.active
    new_id = windows.next_id
    new_window = Map.fetch!(windows.map, active)

    # Split size 0 means "even split" (WindowTree.clamp_size/2).
    tree = {:split, direction, {:leaf, active}, {:leaf, new_id}, 0}

    updated = %{
      windows
      | tree: tree,
        map: Map.put(windows.map, new_id, %{new_window | id: new_id}),
        next_id: new_id + 1
    }

    %{state | workspace: SessionState.set_windows(state.workspace, updated)}
  end
end
