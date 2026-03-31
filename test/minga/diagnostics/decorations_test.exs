defmodule Minga.Diagnostics.DecorationsTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Core.Decorations
  alias Minga.Diagnostics
  alias Minga.Diagnostics.Decorations, as: DiagDecorations
  alias Minga.Diagnostics.Diagnostic

  @gutter_colors %MingaEditor.UI.Theme.Gutter{
    fg: 0x555555,
    current_fg: 0xBBC2CF,
    error_fg: 0xFF6C6B,
    warning_fg: 0xECBE7B,
    info_fg: 0x51AFEF,
    hint_fg: 0x5B6268
  }

  defp make_diagnostic(severity, start_line, start_col, end_line, end_col) do
    %Diagnostic{
      range: %{
        start_line: start_line,
        start_col: start_col,
        end_line: end_line,
        end_col: end_col
      },
      severity: severity,
      message: "test #{severity}"
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
      {:ok, pid} = BufferServer.start_link(content: "hello world\nfoo bar")
      uri = "file:///test/file.ex"

      # Publish a diagnostic
      Diagnostics.publish(ctx.diag_name, :test, uri, [
        make_diagnostic(:error, 0, 0, 0, 5)
      ])

      # Apply decorations
      DiagDecorations.apply(pid, uri, @gutter_colors, ctx.diag_name)

      # Verify the decoration was created
      decs = BufferServer.decorations(pid)
      ranges = Decorations.highlights_for_line(decs, 0)
      assert length(ranges) == 1

      [range] = ranges
      assert range.style.underline == true
      assert range.style.underline_color == @gutter_colors.error_fg
      assert range.group == :diagnostics
    end

    test "multiple diagnostics on same line create multiple ranges", ctx do
      {:ok, pid} = BufferServer.start_link(content: "hello world foo bar")
      uri = "file:///test/multi.ex"

      Diagnostics.publish(ctx.diag_name, :test, uri, [
        make_diagnostic(:error, 0, 0, 0, 5),
        make_diagnostic(:warning, 0, 12, 0, 15)
      ])

      DiagDecorations.apply(pid, uri, @gutter_colors, ctx.diag_name)

      decs = BufferServer.decorations(pid)
      ranges = Decorations.highlights_for_line(decs, 0)
      assert length(ranges) == 2
    end

    test "zero-width diagnostic is skipped", ctx do
      {:ok, pid} = BufferServer.start_link(content: "hello")
      uri = "file:///test/point.ex"

      Diagnostics.publish(ctx.diag_name, :test, uri, [
        make_diagnostic(:error, 0, 5, 0, 5)
      ])

      DiagDecorations.apply(pid, uri, @gutter_colors, ctx.diag_name)

      decs = BufferServer.decorations(pid)
      ranges = Decorations.highlights_for_line(decs, 0)
      assert ranges == []
    end

    test "clear/1 removes diagnostic decorations", ctx do
      {:ok, pid} = BufferServer.start_link(content: "hello")
      uri = "file:///test/clear.ex"

      Diagnostics.publish(ctx.diag_name, :test, uri, [
        make_diagnostic(:error, 0, 0, 0, 5)
      ])

      DiagDecorations.apply(pid, uri, @gutter_colors, ctx.diag_name)
      assert length(Decorations.highlights_for_line(BufferServer.decorations(pid), 0)) == 1

      DiagDecorations.clear(pid)
      assert Decorations.highlights_for_line(BufferServer.decorations(pid), 0) == []
    end

    test "re-apply replaces old decorations", ctx do
      {:ok, pid} = BufferServer.start_link(content: "hello world")
      uri = "file:///test/replace.ex"

      # First apply: one error
      Diagnostics.publish(ctx.diag_name, :test, uri, [
        make_diagnostic(:error, 0, 0, 0, 5)
      ])

      DiagDecorations.apply(pid, uri, @gutter_colors, ctx.diag_name)
      assert length(Decorations.highlights_for_line(BufferServer.decorations(pid), 0)) == 1

      # Second apply: different diagnostic
      Diagnostics.publish(ctx.diag_name, :test, uri, [
        make_diagnostic(:warning, 0, 6, 0, 11)
      ])

      DiagDecorations.apply(pid, uri, @gutter_colors, ctx.diag_name)

      # Old error should be gone, new warning should exist
      decs = BufferServer.decorations(pid)
      assert Decorations.highlights_for_line(decs, 0) |> length() == 1

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
        {:ok, pid} = BufferServer.start_link(content: "hello world")
        uri = "file:///test/color_#{severity}.ex"

        Diagnostics.publish(ctx.diag_name, :test, uri, [
          make_diagnostic(severity, 0, 0, 0, 5)
        ])

        DiagDecorations.apply(pid, uri, @gutter_colors, ctx.diag_name)

        [range] = Decorations.highlights_for_line(BufferServer.decorations(pid), 0)

        assert range.style.underline_color == expected_color,
               "#{severity} underline should be #{inspect(expected_color)}"
      end
    end

    test "diagnostic decorations don't affect other groups", ctx do
      {:ok, pid} = BufferServer.start_link(content: "hello world")
      uri = "file:///test/groups.ex"

      # Add a search highlight
      BufferServer.batch_decorations(pid, fn decs ->
        {_id, decs} =
          Decorations.add_highlight(decs, {0, 0}, {0, 5},
            style: Minga.Core.Face.new(fg: 0x00FF00),
            group: :search
          )

        decs
      end)

      # Apply diagnostic decorations
      Diagnostics.publish(ctx.diag_name, :test, uri, [
        make_diagnostic(:error, 0, 6, 0, 11)
      ])

      DiagDecorations.apply(pid, uri, @gutter_colors, ctx.diag_name)

      decs = BufferServer.decorations(pid)
      ranges = Decorations.highlights_for_line(decs, 0)
      # Both search and diagnostic ranges should exist
      assert length(ranges) == 2
      groups = Enum.map(ranges, & &1.group) |> Enum.sort()
      assert groups == [:diagnostics, :search]
    end
  end
end
