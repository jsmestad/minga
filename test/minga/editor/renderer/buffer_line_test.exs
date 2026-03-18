defmodule Minga.Editor.Renderer.BufferLineTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.Renderer.BufferLine
  alias Minga.Editor.Renderer.Context
  alias Minga.Editor.Viewport

  # ── Test helpers ──────────────────────────────────────────────────────────

  # Converts a DisplayList draw tuple into a map for easy assertion.
  defp decode_draw({row, col, text, style}) do
    %{
      row: row,
      col: col,
      text: text,
      fg: style.fg || 0xFFFFFF,
      bg: style.bg || 0x000000,
      attrs: style
    }
  end

  defp decode_draw(other), do: {:unknown, other}

  # Decode all draw tuples, filtering to maps only.
  defp decode_all(cmds) do
    cmds
    |> List.flatten()
    |> Enum.map(&decode_draw/1)
    |> Enum.filter(&is_map/1)
  end

  # Builds a minimal valid line_params map for testing.
  defp make_params(overrides \\ %{}) do
    ctx = %Context{
      viewport: Viewport.new(24, 80),
      gutter_w: 4,
      content_w: 76
    }

    defaults = %{
      line_text: "hello world",
      buf_line: 0,
      cursor_line: 0,
      byte_offset: 0,
      screen_row: 0,
      ctx: ctx,
      ln_style: :hybrid,
      gutter_w: 4,
      sign_w: 0,
      wrap_entry: nil,
      max_rows: 24,
      row_offset: 0,
      col_offset: 0
    }

    Map.merge(defaults, overrides)
  end

  defp make_ctx(overrides) do
    base = %Context{
      viewport: Viewport.new(24, 80),
      gutter_w: Map.get(overrides, :gutter_w, 4),
      content_w: Map.get(overrides, :content_w, 76)
    }

    Map.merge(base, Map.drop(overrides, [:gutter_w, :content_w]))
  end

  # ── No-wrap rendering ───────────────────────────────────────────────────

  describe "render/1 without wrap" do
    test "returns exactly 1 row consumed" do
      {_g, _c, rows} = BufferLine.render(make_params())
      assert rows == 1
    end

    test "produces content commands with text on the correct screen row" do
      {_g, content, 1} = BufferLine.render(make_params(%{screen_row: 5}))
      decoded = decode_all(content)
      assert decoded != []
      Enum.each(decoded, fn cmd -> assert cmd.row == 5 end)
    end

    test "content commands start at the gutter width column" do
      ctx = make_ctx(%{gutter_w: 6, content_w: 74})

      {_g, content, 1} =
        BufferLine.render(make_params(%{gutter_w: 6, ctx: ctx}))

      decoded = decode_all(content)
      # At least one content command should start at gutter_w
      assert Enum.any?(decoded, fn cmd -> cmd.col == 6 end)
    end

    test "produces gutter commands (line number)" do
      {gutters, _c, 1} = BufferLine.render(make_params(%{ln_style: :absolute}))
      decoded = decode_all(gutters)
      assert decoded != []
      # Line number for buf_line 0 in :absolute mode is "1"
      number_cmd = Enum.find(decoded, fn cmd -> String.contains?(cmd.text, "1") end)
      assert number_cmd != nil
    end

    test "no sign column commands when sign_w is 0" do
      {gutters, _c, 1} = BufferLine.render(make_params(%{sign_w: 0}))
      decoded = decode_all(gutters)
      # With sign_w: 0 and has_sign_column: false, only line number gutter
      assert length(decoded) == 1
    end

    test "includes sign column when has_sign_column is true" do
      ctx = make_ctx(%{has_sign_column: true})

      {gutters, _c, 1} =
        BufferLine.render(make_params(%{ctx: ctx, sign_w: 2, gutter_w: 6}))

      decoded = decode_all(gutters)
      # Should have sign command + line number command
      assert length(decoded) == 2
    end

    test "diagnostic sign appears when buffer line has a diagnostic" do
      ctx = make_ctx(%{has_sign_column: true, diagnostic_signs: %{0 => :error}})

      {gutters, _c, 1} =
        BufferLine.render(make_params(%{ctx: ctx, sign_w: 2, gutter_w: 6, buf_line: 0}))

      decoded = decode_all(gutters)
      sign_cmd = Enum.find(decoded, fn cmd -> cmd.col == 0 end)
      assert sign_cmd != nil
      assert String.contains?(sign_cmd.text, "E")
    end

    test "git sign appears when buffer line has a git change" do
      ctx = make_ctx(%{has_sign_column: true, git_signs: %{0 => :added}})

      {gutters, _c, 1} =
        BufferLine.render(make_params(%{ctx: ctx, sign_w: 2, gutter_w: 6, buf_line: 0}))

      decoded = decode_all(gutters)
      sign_cmd = Enum.find(decoded, fn cmd -> cmd.col == 0 end)
      assert sign_cmd != nil
    end

    test "content text matches the line_text" do
      {_g, content, 1} = BufferLine.render(make_params(%{line_text: "fn hello do"}))
      decoded = decode_all(content)
      all_text = Enum.map_join(decoded, "", fn cmd -> cmd.text end)
      assert all_text == "fn hello do"
    end
  end

  # ── Wrapped rendering ──────────────────────────────────────────────────

  describe "render/1 with wrap" do
    test "returns the correct number of rows consumed" do
      wrap_entry = [
        %{text: "hello ", byte_offset: 0},
        %{text: "world", byte_offset: 6}
      ]

      {_g, _c, rows} =
        BufferLine.render(make_params(%{line_text: "hello world", wrap_entry: wrap_entry}))

      assert rows == 2
    end

    test "single-element wrap entry produces 1 row" do
      wrap_entry = [%{text: "short", byte_offset: 0}]
      {_g, _c, rows} = BufferLine.render(make_params(%{wrap_entry: wrap_entry}))
      assert rows == 1
    end

    test "content commands are placed on consecutive screen rows" do
      wrap_entry = [
        %{text: "hello ", byte_offset: 0},
        %{text: "world", byte_offset: 6}
      ]

      {_g, content, 2} =
        BufferLine.render(
          make_params(%{
            line_text: "hello world",
            wrap_entry: wrap_entry,
            screen_row: 3
          })
        )

      decoded = decode_all(content)
      rows = decoded |> Enum.map(& &1.row) |> Enum.uniq() |> Enum.sort()
      assert rows == [3, 4]
    end

    test "gutter line number only on first visual row" do
      wrap_entry = [
        %{text: "hello ", byte_offset: 0},
        %{text: "world", byte_offset: 6}
      ]

      {gutters, _c, 2} =
        BufferLine.render(
          make_params(%{
            line_text: "hello world",
            wrap_entry: wrap_entry,
            buf_line: 5,
            ln_style: :absolute
          })
        )

      decoded = decode_all(gutters)
      # First row should have line number "6" (buf_line 5, 1-indexed)
      first_row_cmds = Enum.filter(decoded, fn cmd -> cmd.row == 0 end)
      assert Enum.any?(first_row_cmds, fn cmd -> String.contains?(cmd.text, "6") end)

      # Second row should have blank gutter (no digits)
      second_row_cmds = Enum.filter(decoded, fn cmd -> cmd.row == 1 end)

      Enum.each(second_row_cmds, fn cmd ->
        assert String.trim(cmd.text) == ""
      end)
    end

    test "sign column only on first visual row" do
      ctx = make_ctx(%{has_sign_column: true, diagnostic_signs: %{0 => :warning}})

      wrap_entry = [
        %{text: "hello ", byte_offset: 0},
        %{text: "world", byte_offset: 6}
      ]

      {gutters, _c, 2} =
        BufferLine.render(
          make_params(%{
            line_text: "hello world",
            wrap_entry: wrap_entry,
            ctx: ctx,
            sign_w: 2,
            gutter_w: 6
          })
        )

      decoded = decode_all(gutters)
      # Sign column command on row 0
      row0_signs = Enum.filter(decoded, fn cmd -> cmd.row == 0 and cmd.col == 0 end)
      assert length(row0_signs) == 1
      assert String.contains?(hd(row0_signs).text, "W")

      # No sign column command on row 1 (just blank gutter)
      row1_at_col0 = Enum.filter(decoded, fn cmd -> cmd.row == 1 and cmd.col == 0 end)
      # Continuation row should not have diagnostic sign
      Enum.each(row1_at_col0, fn cmd ->
        refute String.contains?(cmd.text, "W")
        refute String.contains?(cmd.text, "E")
      end)
    end

    test "each visual row renders the correct text slice" do
      wrap_entry = [
        %{text: "hello ", byte_offset: 0},
        %{text: "world", byte_offset: 6}
      ]

      {_g, content, 2} =
        BufferLine.render(
          make_params(%{
            line_text: "hello world",
            wrap_entry: wrap_entry,
            gutter_w: 4
          })
        )

      decoded = decode_all(content)

      row0_text =
        decoded
        |> Enum.filter(fn cmd -> cmd.row == 0 end)
        |> Enum.map_join("", fn cmd -> cmd.text end)

      row1_text =
        decoded
        |> Enum.filter(fn cmd -> cmd.row == 1 end)
        |> Enum.map_join("", fn cmd -> cmd.text end)

      assert row0_text == "hello "
      assert row1_text == "world"
    end

    test "three visual rows are handled correctly" do
      wrap_entry = [
        %{text: "aaa ", byte_offset: 0},
        %{text: "bbb ", byte_offset: 4},
        %{text: "ccc", byte_offset: 8}
      ]

      {_g, _c, rows} =
        BufferLine.render(make_params(%{line_text: "aaa bbb ccc", wrap_entry: wrap_entry}))

      assert rows == 3
    end
  end

  # ── Row/col offset (split windows) ─────────────────────────────────────

  describe "render/1 with row/col offset" do
    test "offsets gutter commands by row_offset and col_offset" do
      {gutters, _c, 1} =
        BufferLine.render(make_params(%{row_offset: 10, col_offset: 20, screen_row: 0}))

      decoded = decode_all(gutters)

      Enum.each(decoded, fn cmd ->
        assert cmd.row >= 10
        assert cmd.col >= 20
      end)
    end

    test "offsets content commands by row_offset and col_offset" do
      {_g, content, 1} =
        BufferLine.render(
          make_params(%{
            row_offset: 5,
            col_offset: 30,
            screen_row: 0,
            gutter_w: 4
          })
        )

      decoded = decode_all(content)

      Enum.each(decoded, fn cmd ->
        assert cmd.row >= 5
        assert cmd.col >= 34
      end)
    end

    test "zero offset leaves commands unchanged" do
      {g1, c1, _} = BufferLine.render(make_params(%{row_offset: 0, col_offset: 0}))
      {g2, c2, _} = BufferLine.render(make_params())
      assert g1 == g2
      assert c1 == c2
    end

    test "offset applies to wrapped visual rows too" do
      wrap_entry = [
        %{text: "hello ", byte_offset: 0},
        %{text: "world", byte_offset: 6}
      ]

      {_g, content, 2} =
        BufferLine.render(
          make_params(%{
            line_text: "hello world",
            wrap_entry: wrap_entry,
            row_offset: 10,
            col_offset: 5,
            screen_row: 0
          })
        )

      decoded = decode_all(content)
      rows = decoded |> Enum.map(& &1.row) |> Enum.uniq() |> Enum.sort()
      assert rows == [10, 11]
    end
  end

  # ── Line number styles ─────────────────────────────────────────────────

  describe "line number styles" do
    test "absolute style shows 1-indexed line number" do
      {gutters, _c, 1} =
        BufferLine.render(make_params(%{buf_line: 9, ln_style: :absolute}))

      decoded = decode_all(gutters)
      assert Enum.any?(decoded, fn cmd -> String.contains?(cmd.text, "10") end)
    end

    test "relative style shows distance from cursor" do
      {gutters, _c, 1} =
        BufferLine.render(make_params(%{buf_line: 5, cursor_line: 3, ln_style: :relative}))

      decoded = decode_all(gutters)
      assert Enum.any?(decoded, fn cmd -> String.contains?(cmd.text, "2") end)
    end

    test "hybrid shows absolute on cursor line, relative elsewhere" do
      # On cursor line
      {gutters_at, _c, 1} =
        BufferLine.render(make_params(%{buf_line: 3, cursor_line: 3, ln_style: :hybrid}))

      decoded_at = decode_all(gutters_at)
      assert Enum.any?(decoded_at, fn cmd -> String.contains?(cmd.text, "4") end)

      # Away from cursor line
      {gutters_away, _c, 1} =
        BufferLine.render(make_params(%{buf_line: 7, cursor_line: 3, ln_style: :hybrid}))

      decoded_away = decode_all(gutters_away)
      assert Enum.any?(decoded_away, fn cmd -> String.contains?(cmd.text, "4") end)
    end

    test ":none style produces no gutter commands" do
      ctx = make_ctx(%{has_sign_column: false})

      {gutters, _c, 1} =
        BufferLine.render(make_params(%{ln_style: :none, gutter_w: 0, ctx: ctx}))

      assert gutters == []
    end
  end

  # ── max_rows clamping ───────────────────────────────────────────────────

  describe "max_rows clamping for wrapped lines" do
    test "stops rendering when screen_row reaches max_rows" do
      # 5 visual rows but only 3 fit on screen
      wrap_entry = [
        %{text: "aaa ", byte_offset: 0},
        %{text: "bbb ", byte_offset: 4},
        %{text: "ccc ", byte_offset: 8},
        %{text: "ddd ", byte_offset: 12},
        %{text: "eee", byte_offset: 16}
      ]

      {_g, content, rows} =
        BufferLine.render(
          make_params(%{
            line_text: "aaa bbb ccc ddd eee",
            wrap_entry: wrap_entry,
            screen_row: 0,
            max_rows: 3
          })
        )

      assert rows == 3

      decoded = decode_all(content)
      rows_rendered = decoded |> Enum.map(& &1.row) |> Enum.uniq() |> Enum.sort()
      assert rows_rendered == [0, 1, 2]
      # No commands on row 3 or 4
      refute Enum.any?(decoded, fn cmd -> cmd.row >= 3 end)
    end

    test "renders all rows when max_rows is large enough" do
      wrap_entry = [
        %{text: "aaa ", byte_offset: 0},
        %{text: "bbb", byte_offset: 4}
      ]

      {_g, _c, rows} =
        BufferLine.render(
          make_params(%{
            line_text: "aaa bbb",
            wrap_entry: wrap_entry,
            max_rows: 100
          })
        )

      assert rows == 2
    end

    test "starting mid-screen respects max_rows boundary" do
      wrap_entry = [
        %{text: "aaa ", byte_offset: 0},
        %{text: "bbb ", byte_offset: 4},
        %{text: "ccc", byte_offset: 8}
      ]

      # Start at row 8 with max 10 rows: only 2 visual rows fit (rows 8, 9)
      {_g, content, rows} =
        BufferLine.render(
          make_params(%{
            line_text: "aaa bbb ccc",
            wrap_entry: wrap_entry,
            screen_row: 8,
            max_rows: 10
          })
        )

      assert rows == 2

      decoded = decode_all(content)
      refute Enum.any?(decoded, fn cmd -> cmd.row >= 10 end)
    end
  end

  # ── Edge cases ─────────────────────────────────────────────────────────

  describe "edge cases" do
    test "empty line text produces valid output" do
      {_g, content, 1} = BufferLine.render(make_params(%{line_text: ""}))
      decoded = decode_all(content)
      all_text = Enum.map_join(decoded, "", fn cmd -> cmd.text end)
      assert all_text == ""
    end

    test "unicode line text renders correctly" do
      {_g, content, 1} = BufferLine.render(make_params(%{line_text: "café 日本語"}))
      decoded = decode_all(content)
      all_text = Enum.map_join(decoded, "", fn cmd -> cmd.text end)
      assert all_text == "café 日本語"
    end

    test "wrapped empty line produces 1 row" do
      wrap_entry = [%{text: "", byte_offset: 0}]
      {_g, _c, rows} = BufferLine.render(make_params(%{line_text: "", wrap_entry: wrap_entry}))
      assert rows == 1
    end

    test "screen_row is respected for first visual row" do
      {_g, content, 1} = BufferLine.render(make_params(%{screen_row: 15}))
      decoded = decode_all(content)
      Enum.each(decoded, fn cmd -> assert cmd.row == 15 end)
    end

    test "buf_line 0 with absolute style shows 1" do
      {gutters, _c, 1} = BufferLine.render(make_params(%{buf_line: 0, ln_style: :absolute}))
      decoded = decode_all(gutters)
      assert Enum.any?(decoded, fn cmd -> String.contains?(cmd.text, "1") end)
    end
  end

  # ── Consistency between nowrap and single-element wrap ─────────────────

  describe "nowrap vs single-element wrap consistency" do
    test "same content is produced for a short line" do
      base = %{line_text: "hello world", gutter_w: 4, sign_w: 0, screen_row: 0}

      {_g1, content_nowrap, 1} = BufferLine.render(make_params(base))

      wrap_entry = [%{text: "hello world", byte_offset: 0}]

      {_g2, content_wrap, 1} =
        BufferLine.render(make_params(Map.put(base, :wrap_entry, wrap_entry)))

      text_nowrap =
        content_nowrap |> decode_all() |> Enum.map_join("", fn c -> c.text end)

      text_wrap =
        content_wrap |> decode_all() |> Enum.map_join("", fn c -> c.text end)

      assert text_nowrap == text_wrap
    end
  end

  # ── Cursorline highlighting ──────────────────────────────────────────────

  describe "cursorline highlighting" do
    @cursorline_bg 0x2C323C

    test "applies cursorline bg to content draws on the cursor line" do
      ctx = make_ctx(%{cursorline_bg: @cursorline_bg})
      params = make_params(%{buf_line: 3, cursor_line: 3, ctx: ctx})
      {_g, content, 1} = BufferLine.render(params)
      decoded = decode_all(content)

      # Every draw should have the cursorline bg
      Enum.each(decoded, fn cmd ->
        assert cmd.bg == @cursorline_bg,
               "expected cursorline bg #{inspect(@cursorline_bg)}, got #{inspect(cmd.bg)} in #{inspect(cmd)}"
      end)
    end

    test "includes a full-width fill draw on the cursor line" do
      ctx = make_ctx(%{cursorline_bg: @cursorline_bg})
      params = make_params(%{buf_line: 0, cursor_line: 0, ctx: ctx})
      {_g, content, 1} = BufferLine.render(params)
      decoded = decode_all(content)

      fill =
        Enum.find(decoded, fn cmd ->
          cmd.bg == @cursorline_bg and String.length(cmd.text) == ctx.content_w
        end)

      assert fill != nil, "expected a full-width fill draw with cursorline bg"
    end

    test "does not apply cursorline bg to non-cursor lines" do
      ctx = make_ctx(%{cursorline_bg: @cursorline_bg})
      params = make_params(%{buf_line: 5, cursor_line: 3, ctx: ctx})
      {_g, content, 1} = BufferLine.render(params)
      decoded = decode_all(content)

      Enum.each(decoded, fn cmd ->
        refute cmd.bg == @cursorline_bg,
               "non-cursor line should not have cursorline bg"
      end)
    end

    test "does not apply cursorline bg when cursorline_bg is nil" do
      ctx = make_ctx(%{cursorline_bg: nil})
      params = make_params(%{buf_line: 0, cursor_line: 0, ctx: ctx})
      {_g, content, 1} = BufferLine.render(params)
      decoded = decode_all(content)

      Enum.each(decoded, fn cmd ->
        refute cmd.bg == @cursorline_bg
      end)
    end

    test "does not apply cursorline bg to reversed (selected) draws on cursor line" do
      ctx =
        make_ctx(%{
          cursorline_bg: @cursorline_bg,
          visual_selection: {:line, 0, 0}
        })

      params = make_params(%{buf_line: 0, cursor_line: 0, ctx: ctx})
      {_g, content, 1} = BufferLine.render(params)

      # Reversed draws (from visual selection) should not have cursorline bg
      reversed_draws =
        content
        |> List.flatten()
        |> Enum.filter(fn {_r, _c, _t, style} -> style.reverse end)

      default_bg = 0x282C34

      Enum.each(reversed_draws, fn {_r, _c, _t, face} ->
        assert face.bg == nil or face.bg == default_bg,
               "reversed (selected) draw should not have cursorline bg applied, got bg: #{inspect(face.bg)}"
      end)

      # The fill draw should still have cursorline bg
      decoded = decode_all(content)
      assert Enum.any?(decoded, fn cmd -> cmd.bg == @cursorline_bg end)
    end
  end

  # ── Nav-flash highlighting ──────────────────────────────────────────────

  describe "nav-flash highlighting" do
    @flash_bg 0x3E4451
    @cursorline_bg 0x2C323C
    @editor_bg 0x282C34

    test "flash overrides cursorline bg on the flash line" do
      flash = %Minga.Editor.NavFlash{line: 5, step: 0, max_steps: 3, timer: nil}

      ctx =
        make_ctx(%{
          cursorline_bg: @cursorline_bg,
          nav_flash: flash,
          nav_flash_bg: @flash_bg,
          editor_bg: @editor_bg
        })

      params = make_params(%{buf_line: 5, cursor_line: 5, ctx: ctx})
      {_g, content, 1} = BufferLine.render(params)
      decoded = decode_all(content)

      # At step 0, the bg should be the full flash_bg (not cursorline_bg)
      fill =
        Enum.find(decoded, fn cmd ->
          String.length(cmd.text) == ctx.content_w
        end)

      assert fill != nil
      assert fill.bg == @flash_bg
    end

    test "flash does not affect non-flash lines" do
      flash = %Minga.Editor.NavFlash{line: 10, step: 0, max_steps: 3, timer: nil}

      ctx =
        make_ctx(%{
          cursorline_bg: @cursorline_bg,
          nav_flash: flash,
          nav_flash_bg: @flash_bg,
          editor_bg: @editor_bg
        })

      # Line 5 is the cursor line but NOT the flash line
      params = make_params(%{buf_line: 5, cursor_line: 5, ctx: ctx})
      {_g, content, 1} = BufferLine.render(params)
      decoded = decode_all(content)

      # Should have cursorline bg, not flash bg
      Enum.each(decoded, fn cmd ->
        refute cmd.bg == @flash_bg,
               "non-flash line should not have flash bg"
      end)
    end

    test "later flash steps produce interpolated colors" do
      flash = %Minga.Editor.NavFlash{line: 0, step: 2, max_steps: 3, timer: nil}

      ctx =
        make_ctx(%{
          cursorline_bg: @cursorline_bg,
          nav_flash: flash,
          nav_flash_bg: @flash_bg,
          editor_bg: @editor_bg
        })

      params = make_params(%{buf_line: 0, cursor_line: 0, ctx: ctx})
      {_g, content, 1} = BufferLine.render(params)
      decoded = decode_all(content)

      fill =
        Enum.find(decoded, fn cmd ->
          String.length(cmd.text) == ctx.content_w
        end)

      assert fill != nil
      # At final step (2 of 3), should be the target (cursorline_bg)
      assert fill.bg == @cursorline_bg
    end
  end
end
