defmodule Minga.Diagnostics.DecorationsTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias Minga.Diagnostics
  alias Minga.Diagnostics.Decorations, as: DiagDecorations
  alias Minga.Diagnostics.Diagnostic

  @gutter_colors %MingaEditor.UI.Theme.Gutter{
    fg: 0x555555,
    current_fg: 0xBBC2CF,
    error_fg: 0xFF6C6B,
    warning_fg: 0xECBE7B,
    info_fg: 0x51AFEF,
    hint_fg: 0x5B6268,
    fold_fg: 0x5B6268
  }

  defp make_diagnostic(severity, start_line, start_col, end_line, end_col, opts \\ []) do
    %Diagnostic{
      range: %{
        start_line: start_line,
        start_col: start_col,
        end_line: end_line,
        end_col: end_col
      },
      severity: severity,
      message: "test #{severity}",
      encoding: Keyword.get(opts, :encoding, :utf8)
    }
  end

  defp setup_diag_server(_ctx) do
    name = :"diag_#{System.unique_integer([:positive])}"
    server = start_supervised!({Diagnostics, name: name})
    %{diag_server: server, diag_name: name}
  end

  describe "apply/3 through the public API" do
    setup :setup_diag_server

    test "creates underline highlight ranges from diagnostics", ctx do
      {:ok, pid} = BufferProcess.start_link(content: "hello world\nfoo bar")
      uri = "file:///test/file.ex"

      # Publish a diagnostic
      Diagnostics.publish(ctx.diag_name, :test, uri, [
        make_diagnostic(:error, 0, 0, 0, 5)
      ])

      # Apply decorations
      DiagDecorations.apply(pid, uri, @gutter_colors, ctx.diag_name)

      decs = BufferProcess.decorations(pid)
      ranges = Decorations.highlights_for_line(decs, 0)
      assert Enum.count(ranges) == 1

      [range] = ranges
      assert range.style.underline == true
      assert range.style.underline_color == @gutter_colors.error_fg
      assert range.group == :diagnostics
    end

    test "multiple diagnostics on same line create multiple ranges", ctx do
      {:ok, pid} = BufferProcess.start_link(content: "hello world foo bar")
      uri = "file:///test/multi.ex"

      Diagnostics.publish(ctx.diag_name, :test, uri, [
        make_diagnostic(:error, 0, 0, 0, 5),
        make_diagnostic(:warning, 0, 12, 0, 15)
      ])

      DiagDecorations.apply(pid, uri, @gutter_colors, ctx.diag_name)

      decs = BufferProcess.decorations(pid)
      ranges = Decorations.highlights_for_line(decs, 0)
      assert Enum.count(ranges) == 2
    end

    test "UTF-16 diagnostics convert to byte-accurate decoration columns", ctx do
      {:ok, pid} = BufferProcess.start_link(content: "\"héllo wörld\" <> undefined_var")
      uri = "file:///test/utf16.ex"

      Diagnostics.publish(ctx.diag_name, :test, uri, [
        make_diagnostic(:error, 0, 17, 0, 30, encoding: :utf16)
      ])

      DiagDecorations.apply(pid, uri, @gutter_colors, ctx.diag_name)

      [range] =
        pid
        |> BufferProcess.decorations()
        |> Decorations.highlights_for_line(0)

      assert range.start == {0, 19}
      assert range.end_ == {0, 32}
    end

    test "UTF-8 diagnostics keep raw decoration columns", ctx do
      {:ok, pid} = BufferProcess.start_link(content: "\"héllo wörld\" <> undefined_var")
      uri = "file:///test/utf8.ex"

      Diagnostics.publish(ctx.diag_name, :test, uri, [
        make_diagnostic(:error, 0, 19, 0, 32, encoding: :utf8)
      ])

      DiagDecorations.apply(pid, uri, @gutter_colors, ctx.diag_name)

      [range] =
        pid
        |> BufferProcess.decorations()
        |> Decorations.highlights_for_line(0)

      assert range.start == {0, 19}
      assert range.end_ == {0, 32}
    end

    test "zero-width diagnostic is skipped", ctx do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      uri = "file:///test/point.ex"

      Diagnostics.publish(ctx.diag_name, :test, uri, [
        make_diagnostic(:error, 0, 5, 0, 5)
      ])

      DiagDecorations.apply(pid, uri, @gutter_colors, ctx.diag_name)

      decs = BufferProcess.decorations(pid)
      ranges = Decorations.highlights_for_line(decs, 0)
      assert ranges == []
    end

    test "clear/1 removes diagnostic decorations", ctx do
      {:ok, pid} = BufferProcess.start_link(content: "hello")
      uri = "file:///test/clear.ex"

      Diagnostics.publish(ctx.diag_name, :test, uri, [
        make_diagnostic(:error, 0, 0, 0, 5)
      ])

      DiagDecorations.apply(pid, uri, @gutter_colors, ctx.diag_name)
      assert Enum.count(Decorations.highlights_for_line(BufferProcess.decorations(pid), 0)) == 1

      DiagDecorations.clear(pid)
      assert Decorations.highlights_for_line(BufferProcess.decorations(pid), 0) == []
    end

    test "re-apply replaces old decorations", ctx do
      {:ok, pid} = BufferProcess.start_link(content: "hello world")
      uri = "file:///test/replace.ex"

      # First apply: one error
      Diagnostics.publish(ctx.diag_name, :test, uri, [
        make_diagnostic(:error, 0, 0, 0, 5)
      ])

      DiagDecorations.apply(pid, uri, @gutter_colors, ctx.diag_name)
      assert Enum.count(Decorations.highlights_for_line(BufferProcess.decorations(pid), 0)) == 1

      # Second apply: different diagnostic
      Diagnostics.publish(ctx.diag_name, :test, uri, [
        make_diagnostic(:warning, 0, 6, 0, 11)
      ])

      DiagDecorations.apply(pid, uri, @gutter_colors, ctx.diag_name)

      # Old error should be gone, new warning should exist
      decs = BufferProcess.decorations(pid)
      assert Decorations.highlights_for_line(decs, 0) |> Enum.count() == 1

      [range] = Decorations.highlights_for_line(decs, 0)
      assert range.start == {0, 6}
    end

    test "each severity uses its theme color for underlines", ctx do
      colors = %{
        error: @gutter_colors.error_fg,
        warning: @gutter_colors.warning_fg,
        info: @gutter_colors.info_fg,
        hint: @gutter_colors.hint_fg
      }

      for {severity, expected_color} <- colors do
        {:ok, pid} = BufferProcess.start_link(content: "hello world")
        uri = "file:///test/color_#{severity}.ex"

        Diagnostics.publish(ctx.diag_name, :test, uri, [
          make_diagnostic(severity, 0, 0, 0, 5)
        ])

        DiagDecorations.apply(pid, uri, @gutter_colors, ctx.diag_name)

        [range] = Decorations.highlights_for_line(BufferProcess.decorations(pid), 0)

        assert range.style.underline_color == expected_color,
               "#{severity} underline should be #{inspect(expected_color)}"
      end
    end

    test "diagnostic decorations don't affect other groups", ctx do
      {:ok, pid} = BufferProcess.start_link(content: "hello world")
      uri = "file:///test/groups.ex"

      BufferProcess.batch_decorations(pid, fn decs ->
        {_id, decs} =
          Decorations.add_highlight(decs, {0, 0}, {0, 5},
            style: Face.new(fg: 0x00FF00),
            group: :search
          )

        decs
      end)

      # Apply diagnostic decorations
      Diagnostics.publish(ctx.diag_name, :test, uri, [
        make_diagnostic(:error, 0, 6, 0, 11)
      ])

      DiagDecorations.apply(pid, uri, @gutter_colors, ctx.diag_name)

      decs = BufferProcess.decorations(pid)
      ranges = Decorations.highlights_for_line(decs, 0)
      # Both search and diagnostic ranges should exist
      assert Enum.count(ranges) == 2
      groups = Enum.map(ranges, & &1.group) |> Enum.sort()
      assert groups == [:diagnostics, :search]
    end

    test "endpoint line runs past the buffer end keep exact line text in published order",
         ctx do
      {:ok, pid} = BufferProcess.start_link(content: "αβγ one\nδε two\nplain\nζη three\na four")
      uri = "file:///test/line_runs.ex"
      search = {{2, 0}, {2, 5}, [style: Face.new(fg: 0x00FF00), group: :search]}
      BufferProcess.batch_decorations(pid, &add_highlights(&1, [search]))

      # Endpoint lines form runs 0-1, 3-5, and 7-9; the buffer ends at line 4.
      Diagnostics.publish(ctx.diag_name, :test, uri, [
        make_diagnostic(:info, 7, 0, 7, 3, encoding: :utf16),
        make_diagnostic(:warning, 3, 2, 5, 1, encoding: :utf16),
        make_diagnostic(:info, 8, 1, 8, 3),
        make_diagnostic(:hint, 4, 0, 4, 1, encoding: :utf16),
        make_diagnostic(:error, 9, 1, 9, 4, encoding: :utf16),
        make_diagnostic(:error, 3, 0, 3, 2, encoding: :utf16),
        make_diagnostic(:error, 0, 1, 1, 2, encoding: :utf16)
      ])

      DiagDecorations.apply(pid, uri, @gutter_colors, ctx.diag_name)

      diagnostic_ranges =
        for {start_pos, end_pos, color, priority} <- [
              {{0, 2}, {1, 4}, @gutter_colors.error_fg, 40},
              {{3, 0}, {3, 4}, @gutter_colors.error_fg, 40},
              {{3, 4}, {5, 0}, @gutter_colors.warning_fg, 30},
              {{4, 0}, {4, 1}, @gutter_colors.hint_fg, 10},
              {{8, 1}, {8, 3}, @gutter_colors.info_fg, 20}
            ] do
          style = Face.new(underline: true, underline_color: color)
          {start_pos, end_pos, [style: style, priority: priority, group: :diagnostics]}
        end

      expected =
        Decorations.new()
        |> Decorations.batch(&add_highlights(&1, [search]))
        |> Decorations.batch(fn decs ->
          decs
          |> Decorations.remove_group(:diagnostics)
          |> add_highlights(diagnostic_ranges)
        end)

      assert visible_highlights(BufferProcess.decorations(pid)) == visible_highlights(expected)
    end
  end

  defp add_highlights(decs, ranges) do
    Enum.reduce(ranges, decs, fn {start_pos, end_pos, opts}, acc ->
      {_id, acc} = Decorations.add_highlight(acc, start_pos, end_pos, opts)
      acc
    end)
  end

  defp visible_highlights(decs) do
    decs
    |> Decorations.highlights_for_lines(0, 10)
    |> Enum.map(&{&1.start, &1.end_, &1.style, &1.priority, &1.group})
  end
end
