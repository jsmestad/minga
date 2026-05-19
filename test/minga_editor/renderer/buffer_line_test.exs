defmodule MingaEditor.Renderer.BufferLineTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Renderer.BufferLine
  alias MingaEditor.Renderer.Context
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.Viewport

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

  defp rendered_text(cmds) do
    cmds
    |> decode_all()
    |> Enum.map_join("", fn cmd -> cmd.text end)
  end

  defp rendered_text_for_row(cmds, row) do
    cmds
    |> decode_all()
    |> Enum.filter(fn cmd -> cmd.row == row end)
    |> Enum.map_join("", fn cmd -> cmd.text end)
  end

  defp rendered_rows(cmds) do
    cmds
    |> decode_all()
    |> Enum.map(& &1.row)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp full_width_fill(cmds, width) do
    cmds
    |> decode_all()
    |> Enum.find(fn cmd -> String.length(cmd.text) == width end)
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

    params = Map.merge(defaults, overrides)
    Map.put_new(params, :sign_ctx, Gutter.SignContext.from_render_context(params.ctx))
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
    test "renders unwrapped line content at the expected row and column" do
      ctx = make_ctx(%{gutter_w: 6, content_w: 74})

      {_g, content, rows} =
        BufferLine.render(
          make_params(%{line_text: "fn hello do", screen_row: 5, gutter_w: 6, ctx: ctx})
        )

      decoded = decode_all(content)

      assert rows == 1
      assert rendered_text(content) == "fn hello do"
      assert decoded != []
      assert Enum.all?(decoded, fn cmd -> cmd.row == 5 end)
      assert Enum.any?(decoded, fn cmd -> cmd.col == 6 end)
    end

    test "renders gutter line number and reserved sign column" do
      {gutters, _c, 1} = BufferLine.render(make_params(%{ln_style: :absolute}))
      decoded = decode_all(gutters)

      assert length(decoded) == 2
      assert Enum.any?(decoded, fn cmd -> String.contains?(cmd.text, "1") end)
    end

    test "renders diagnostic and git signs with their configured colors" do
      cases = [
        {%{diagnostic_signs: %{0 => :error}}, "E ", fn ctx -> ctx.gutter_colors.error_fg end},
        {%{git_signs: %{0 => :added}}, "▎ ", fn ctx -> ctx.git_colors.added_fg end}
      ]

      for {ctx_overrides, text, color} <- cases do
        ctx = make_ctx(Map.put(ctx_overrides, :has_sign_column, true))

        {gutters, _c, 1} =
          BufferLine.render(make_params(%{ctx: ctx, sign_w: 2, gutter_w: 6, buf_line: 0}))

        sign_cmd = Enum.find(decode_all(gutters), fn cmd -> cmd.text == text end)
        assert sign_cmd != nil
        assert sign_cmd.fg == color.(ctx)
      end
    end

    test "renders indent guides over leading whitespace" do
      ctx =
        make_ctx(%{
          gutter_w: 4,
          content_w: 20,
          tab_width: 2,
          indent_guide_face: Minga.Core.Face.new(fg: 0x111111),
          indent_guide_active_face: Minga.Core.Face.new(fg: 0x222222)
        })

      {_g, content, 1} =
        BufferLine.render(
          make_params(%{
            line_text: "      value",
            ctx: ctx,
            indent_guide_cols: [%{col: 2, active: false}, %{col: 4, active: true}]
          })
        )

      decoded = decode_all(content)
      inactive = Enum.find(decoded, fn cmd -> cmd.text == "│" and cmd.col == 6 end)
      active = Enum.find(decoded, fn cmd -> cmd.text == "│" and cmd.col == 8 end)

      assert inactive.fg == 0x111111
      assert active.fg == 0x222222
    end
  end

  # ── Wrapped rendering ──────────────────────────────────────────────────

  describe "render/1 with wrap" do
    test "reports rows consumed for wrap entries" do
      cases = [
        {"hello world", [%{text: "hello ", byte_offset: 0}, %{text: "world", byte_offset: 6}], 2},
        {"short", [%{text: "short", byte_offset: 0}], 1},
        {"aaa bbb ccc",
         [
           %{text: "aaa ", byte_offset: 0},
           %{text: "bbb ", byte_offset: 4},
           %{text: "ccc", byte_offset: 8}
         ], 3}
      ]

      for {line_text, wrap_entry, expected_rows} <- cases do
        {_g, _c, rows} =
          BufferLine.render(make_params(%{line_text: line_text, wrap_entry: wrap_entry}))

        assert rows == expected_rows
      end
    end

    test "content commands are placed on consecutive screen rows with matching text" do
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

      assert rendered_rows(content) == [3, 4]
      assert rendered_text_for_row(content, 3) == "hello "
      assert rendered_text_for_row(content, 4) == "world"
    end

    test "gutter line number and sign only appear on the first visual row" do
      ctx = make_ctx(%{has_sign_column: true, diagnostic_signs: %{5 => :warning}})

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
            ln_style: :absolute,
            ctx: ctx,
            sign_w: 2,
            gutter_w: 6
          })
        )

      decoded = decode_all(gutters)
      row0 = Enum.filter(decoded, fn cmd -> cmd.row == 0 end)
      row1 = Enum.filter(decoded, fn cmd -> cmd.row == 1 end)

      assert Enum.any?(row0, fn cmd -> String.contains?(cmd.text, "6") end)
      assert Enum.any?(row0, fn cmd -> cmd.col == 0 and String.contains?(cmd.text, "W") end)

      Enum.each(row1, fn cmd ->
        assert String.trim(cmd.text) == ""
        refute String.contains?(cmd.text, "W")
        refute String.contains?(cmd.text, "E")
      end)
    end

    test "breakindent rows render source text with an artificial indent prefix" do
      wrap_entry = [
        %{text: "    alpha ", source_text: "    alpha ", byte_offset: 0, indent_width: 0},
        %{text: "    beta", source_text: "beta", byte_offset: 10, indent_width: 4}
      ]

      {_g, content, 2} =
        BufferLine.render(
          make_params(%{
            line_text: "    alpha beta",
            wrap_entry: wrap_entry,
            gutter_w: 4
          })
        )

      decoded = decode_all(content)

      row1_text =
        decoded
        |> Enum.filter(fn cmd -> cmd.row == 1 end)
        |> Enum.map_join("", fn cmd -> cmd.text end)

      assert row1_text == "    beta"
    end
  end

  # ── Row/col offset (split windows) ─────────────────────────────────────

  describe "render/1 with row/col offset" do
    test "offsets gutter and content commands by row_offset and col_offset" do
      cases = [
        {:gutters, %{row_offset: 10, col_offset: 20, screen_row: 0}, 10, 20},
        {:content, %{row_offset: 5, col_offset: 30, screen_row: 0, gutter_w: 4}, 5, 34}
      ]

      for {command_group, params, min_row, min_col} <- cases do
        {gutters, content, 1} = BufferLine.render(make_params(params))
        commands = if command_group == :gutters, do: gutters, else: content

        Enum.each(decode_all(commands), fn cmd ->
          assert cmd.row >= min_row
          assert cmd.col >= min_col
        end)
      end
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
    test "line number styles render the expected value" do
      cases = [
        {%{buf_line: 9, ln_style: :absolute}, "10"},
        {%{buf_line: 0, ln_style: :absolute}, "1"},
        {%{buf_line: 5, cursor_line: 3, ln_style: :relative}, "2"},
        {%{buf_line: 3, cursor_line: 3, ln_style: :hybrid}, "4"},
        {%{buf_line: 7, cursor_line: 3, ln_style: :hybrid}, "4"}
      ]

      for {params, expected_text} <- cases do
        {gutters, _c, 1} = BufferLine.render(make_params(params))

        assert Enum.any?(decode_all(gutters), fn cmd ->
                 String.contains?(cmd.text, expected_text)
               end)
      end
    end

    test ":none style produces only sign column command" do
      {gutters, _c, 1} =
        BufferLine.render(make_params(%{ln_style: :none, gutter_w: 2, sign_w: 2}))

      decoded = decode_all(gutters)
      # Sign column is always reserved, but no line number
      assert length(decoded) == 1
      assert Enum.all?(decoded, fn cmd -> not Regex.match?(~r/\d/, cmd.text) end)
    end
  end

  # ── max_rows clamping ───────────────────────────────────────────────────

  describe "max_rows clamping for wrapped lines" do
    test "renders only wrapped rows that fit before max_rows" do
      cases = [
        %{
          line_text: "aaa bbb ccc ddd eee",
          wrap_entry: [
            %{text: "aaa ", byte_offset: 0},
            %{text: "bbb ", byte_offset: 4},
            %{text: "ccc ", byte_offset: 8},
            %{text: "ddd ", byte_offset: 12},
            %{text: "eee", byte_offset: 16}
          ],
          screen_row: 0,
          max_rows: 3,
          expected_rows: 3,
          expected_rendered_rows: [0, 1, 2]
        },
        %{
          line_text: "aaa bbb",
          wrap_entry: [%{text: "aaa ", byte_offset: 0}, %{text: "bbb", byte_offset: 4}],
          screen_row: 0,
          max_rows: 100,
          expected_rows: 2,
          expected_rendered_rows: [0, 1]
        },
        %{
          line_text: "aaa bbb ccc",
          wrap_entry: [
            %{text: "aaa ", byte_offset: 0},
            %{text: "bbb ", byte_offset: 4},
            %{text: "ccc", byte_offset: 8}
          ],
          screen_row: 8,
          max_rows: 10,
          expected_rows: 2,
          expected_rendered_rows: [8, 9]
        }
      ]

      for params <- cases do
        render_params = Map.take(params, [:line_text, :wrap_entry, :screen_row, :max_rows])
        {_g, content, rows} = BufferLine.render(make_params(render_params))

        assert rows == params.expected_rows
        assert rendered_rows(content) == params.expected_rendered_rows
        refute Enum.any?(decode_all(content), fn cmd -> cmd.row >= params.max_rows end)
      end
    end
  end

  # ── Edge cases ─────────────────────────────────────────────────────────

  describe "edge cases" do
    test "renders empty and unicode line text" do
      for line_text <- ["", "café 日本語"] do
        {_g, content, 1} = BufferLine.render(make_params(%{line_text: line_text}))
        assert rendered_text(content) == line_text
      end
    end

    test "wrapped empty line produces 1 row" do
      wrap_entry = [%{text: "", byte_offset: 0}]
      {_g, _c, rows} = BufferLine.render(make_params(%{line_text: "", wrap_entry: wrap_entry}))
      assert rows == 1
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

      assert rendered_text(content_nowrap) == rendered_text(content_wrap)
    end
  end

  # ── Cursorline highlighting ──────────────────────────────────────────────

  describe "cursorline highlighting" do
    @cursorline_bg 0x2C323C

    test "applies cursorline bg and full-width fill on the cursor line" do
      ctx = make_ctx(%{cursorline_bg: @cursorline_bg})
      params = make_params(%{buf_line: 3, cursor_line: 3, ctx: ctx})
      {_g, content, 1} = BufferLine.render(params)

      Enum.each(decode_all(content), fn cmd ->
        assert cmd.bg == @cursorline_bg,
               "expected cursorline bg #{inspect(@cursorline_bg)}, got #{inspect(cmd.bg)} in #{inspect(cmd)}"
      end)

      fill = full_width_fill(content, ctx.content_w)
      assert fill != nil, "expected a full-width fill draw with cursorline bg"
      assert fill.bg == @cursorline_bg
    end

    test "does not apply cursorline bg outside the enabled cursor line" do
      cases = [
        {%{cursorline_bg: @cursorline_bg}, %{buf_line: 5, cursor_line: 3},
         "non-cursor line should not have cursorline bg"},
        {%{cursorline_bg: nil}, %{buf_line: 0, cursor_line: 0},
         "nil cursorline_bg should not apply cursorline bg"}
      ]

      for {ctx_overrides, params_overrides, message} <- cases do
        ctx = make_ctx(ctx_overrides)
        params = make_params(Map.put(params_overrides, :ctx, ctx))
        {_g, content, 1} = BufferLine.render(params)

        Enum.each(decode_all(content), fn cmd ->
          refute cmd.bg == @cursorline_bg, message
        end)
      end
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

    test "flash line fill color follows flash interpolation step" do
      cases = [
        {5, 0, @flash_bg},
        {0, 2, @cursorline_bg}
      ]

      for {line, step, expected_bg} <- cases do
        flash = %MingaEditor.NavFlash{line: line, step: step, max_steps: 3, timer: nil}

        ctx =
          make_ctx(%{
            cursorline_bg: @cursorline_bg,
            nav_flash: flash,
            nav_flash_bg: @flash_bg,
            editor_bg: @editor_bg
          })

        params = make_params(%{buf_line: line, cursor_line: line, ctx: ctx})
        {_g, content, 1} = BufferLine.render(params)
        fill = full_width_fill(content, ctx.content_w)

        assert fill != nil
        assert fill.bg == expected_bg
      end
    end

    test "flash does not affect non-flash lines" do
      flash = %MingaEditor.NavFlash{line: 10, step: 0, max_steps: 3, timer: nil}

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
  end
end
