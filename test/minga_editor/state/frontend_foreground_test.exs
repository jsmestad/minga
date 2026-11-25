defmodule MingaEditor.State.FrontendForegroundTest do
  @moduledoc "What the editor keeps of a frontend connection's own reports: where it is, and what its terminal can do."
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.TerminalReport
  alias MingaEditor.State.Frontend

  test "the foreground is unknown until the frontend reports it" do
    assert Frontend.foreground(Frontend.new()) == :unknown
  end

  test "a report replaces what was known, from every earlier status" do
    for from <- [:unknown, :foreground, :background], to <- [:foreground, :background] do
      frontend =
        if from == :unknown,
          do: Frontend.new(),
          else: Frontend.report_foreground(Frontend.new(), from)

      assert frontend |> Frontend.report_foreground(to) |> Frontend.foreground() == to
    end
  end

  test "a terminal report replaces the earlier one whole" do
    first = TerminalReport.new(true_color: :pending, hyperlinks: :detected)
    second = TerminalReport.new(true_color: :detected)

    frontend = Frontend.new() |> Frontend.accept_terminal_report(first)
    assert Frontend.terminal_report(frontend) == first

    frontend = Frontend.accept_terminal_report(frontend, second)
    assert Frontend.terminal_report(frontend) == second
    assert TerminalReport.status(Frontend.terminal_report(frontend), :hyperlinks) == :unknown
  end

  test "a frontend without a host terminal has no report" do
    assert Frontend.terminal_report(Frontend.new()) == nil
  end

  test "a new connection forgets what the last one reported about itself" do
    frontend =
      Frontend.new()
      |> Frontend.report_foreground(:background)
      |> Frontend.accept_terminal_report(TerminalReport.new(true_color: :detected))
      |> Frontend.clear_connection_reports()

    assert Frontend.foreground(frontend) == :unknown
    assert Frontend.terminal_report(frontend) == nil
  end
end
